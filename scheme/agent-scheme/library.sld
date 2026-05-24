;;; Portable Agent Scheme library resolver support.
;;;
;;; This library owns source-library discovery, import-set resolution, and
;;; define-library evaluation without importing the evaluator module.

(define-library (agent-scheme library)
  (export agent-scheme-standard-source-library-specs
          agent-scheme-install-library-backend!
          import-form?
          define-library-form?
          eval-import
          eval-define-library
          resolve-library
          library-available?
          library-name-key
          library-registry-ref
          library-registry-set!
          export-specs
          ensure-compatible-import-bindings
          path-policy-allows-file?
          path-directory
          read-file-string
          with-include-directory
          form-named?)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (agent-scheme reader)
          (except (agent-scheme runtime) make-parameter)
          (agent-scheme base))
  (begin

    ;; Backend hook resolving interpreter primitive implementations.
    (define library-primitive-resolver
      (lambda (name)
        (eval-error "library primitive backend is not installed" name)))
    ;; Backend hook for host-capability-denied primitive factories.
    (define library-policy-denied-primitive
      (lambda (description)
        (eval-error "library policy backend is not installed" description)))
    ;; Backend hook for evaluating library body forms.
    (define library-trampoline
      (lambda (sequence environment context)
        (eval-error "library trampoline backend is not installed")))
    ;; Backend hook for constructing syntax environments.
    (define library-make-empty-syntax-environment
      (lambda (parent)
        (eval-error "library syntax environment backend is not installed")))
    ;; Backend hook for syntax-environment lookup.
    (define library-syntax-environment-ref
      (lambda (syntax-environment name)
        (eval-error "library syntax lookup backend is not installed" name)))
    ;; Backend hook for scoped syntax-environment evaluation.
    (define library-with-syntax-environment
      (lambda (context syntax-environment thunk)
        (eval-error "library syntax scope backend is not installed")))

    ;; Install interpreter and macro callbacks used by library resolution.
    (define (agent-scheme-install-library-backend!
             primitive-resolver policy-denied trampoline
             make-empty-syntax-environment syntax-environment-ref
             with-syntax-environment)
      (set! library-primitive-resolver primitive-resolver)
      (set! library-policy-denied-primitive policy-denied)
      (set! library-trampoline trampoline)
      (set! library-make-empty-syntax-environment make-empty-syntax-environment)
      (set! library-syntax-environment-ref syntax-environment-ref)
      (set! library-with-syntax-environment with-syntax-environment)
      agent-scheme-unspecified)

    ;; Resolve a primitive implementation identifier through the backend.
    (define (library-primitive-implementation name)
      (library-primitive-resolver name))

    ;; Construct a primitive spec from a backend implementation identifier.
    (define (library-primitive-spec name implementation minimum maximum)
      (list name
            (library-primitive-implementation implementation)
            minimum
            maximum))

    ;; Bootstrap libraries are registered lazily into the current context.  The
    ;; required base library snapshots the active base environment; smaller
    ;; standard libraries are subsets, primitive wrappers, or source libraries.
    (define empty-emacs-capability-library-keys
      '((emacs buffer)
        (emacs buffer edit)
        (emacs command)
        (emacs diff)
        (emacs frame)
        (emacs network)
        (emacs process)
        (emacs project)
        (emacs vcs)
        (emacs vcs mutation)
        (emacs window)))

    ;; Standard library keys recognized by the portable library registry.
    (define standard-library-keys
      '((scheme case-lambda)
        (scheme char)
        (scheme complex)
        (scheme cxr)
        (scheme eval)
        (scheme file)
        (scheme inexact)
        (scheme lazy)
        (scheme load)
        (scheme process-context)
        (scheme read)
        (scheme repl)
        (scheme r5rs)
        (scheme time)
        (scheme write)))

    ;; Agent interaction library keys recognized by the portable registry.
    (define agent-library-keys
      '((agent io)
        (agent approval)
        (agent debugger)
        (agent diff)
        (agent vcs)
        (agent network)
        (agent capability)
        (agent capability primitive)
        (agent memory)
        (agent redaction)))

    ;; Checked-in Agent Scheme source libraries loaded by the portable
    ;; evaluator when a public agent library needs syntax definitions.
    (define agent-source-library-load-paths
      '(((agent capability)
         "scheme/agent/capability.sld"
         "agent/capability.sld")
        ((agent diff)
         "scheme/agent/diff.sld"
         "agent/diff.sld")
        ((agent vcs)
         "scheme/agent/vcs.sld"
         "agent/vcs.sld")
        ((agent network)
         "scheme/agent/network.sld"
         "agent/network.sld")))

    ;; Checked-in standard libraries loaded as portable Scheme source files.
    (define standard-source-library-load-paths
      '(((scheme case-lambda)
         "scheme/standard-library/case-lambda.sld"
         "standard-library/case-lambda.sld")
        ((scheme lazy)
         "scheme/standard-library/lazy.sld"
         "standard-library/lazy.sld")))

    ;; Cache selected source path and contents by standard library key.
    (define standard-source-library-source-cache '())

    ;; Cache selected source path and contents by Agent library key.
    (define agent-source-library-source-cache '())

    ;; Return DATUM's list elements, or #f when DATUM is not a proper list.
    (define (proper-list-elements/maybe datum)
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else #f))))

    ;; Report whether DATUM is a proper R7RS library name.
    (define (proper-library-name? datum)
      (and (pair? datum)
           (let ((parts (proper-list-elements/maybe datum)))
             (and parts
                  (let loop ((rest parts))
                    (cond
                     ((null? rest) #t)
                     ((or (symbol? (car rest))
                          (and (agent-scheme-number? (car rest))
                               (eq? (agent-scheme-number-kind (car rest))
                                    'integer)
                               (eq? (agent-scheme-number-exactness (car rest))
                                    'exact)
                               (>= (agent-scheme-number-value (car rest)) 0)))
                      (loop (cdr rest)))
                     (else #f)))))))

    ;; Validate and return NAME as a library registry key.
    (define (library-name-key name)
      (if (proper-library-name? name)
          name
          (eval-error "invalid library name" name)))

    ;; Search ALIST for KEY using equal? comparison.
    (define (assoc/equal key alist)
      (cond
       ((null? alist) #f)
       ((equal? key (caar alist)) (car alist))
       (else (assoc/equal key (cdr alist)))))

    ;; Return the configured path candidates for source-backed standard library
    ;; KEY.
    (define (standard-source-library-paths key)
      (let ((entry (assoc/equal key standard-source-library-load-paths)))
        (if entry
            (cdr entry)
            (eval-error "standard source library is not available" key))))

    ;; Read KEY's source from the first path that works in this host layout.
    (define (load-standard-source-library-source key)
      (let try ((paths (standard-source-library-paths key)))
        (if (null? paths)
            (eval-error "unable to load standard source library" key)
            (guard (condition
                    (else (try (cdr paths))))
              (let ((source
                     (call-with-input-file
                         (car paths)
                       read-port-string)))
                (cons (car paths) source))))))

    ;; Return cached source-file/source pair for source-backed standard library
    ;; KEY.
    (define (standard-source-library-source-entry key)
      (let ((cached (assoc/equal key standard-source-library-source-cache)))
        (if cached
            (cdr cached)
            (let ((loaded (load-standard-source-library-source key)))
              (set! standard-source-library-source-cache
                    (cons (cons key loaded)
                          standard-source-library-source-cache))
              loaded))))

    ;; Return KEY's portable source text.
    (define (standard-source-library-source key)
      (cdr (standard-source-library-source-entry key)))

    ;; Return configured source path candidates for Agent library KEY.
    (define (agent-source-library-paths key)
      (let ((entry (assoc/equal key agent-source-library-load-paths)))
        (if entry
            (cdr entry)
            (eval-error "agent source library is not available" key))))

    ;; Read Agent library KEY's source from the first usable path.
    (define (load-agent-source-library-source key)
      (let try ((paths (agent-source-library-paths key)))
        (if (null? paths)
            (eval-error "unable to load agent source library" key)
            (guard (condition
                    (else (try (cdr paths))))
              (let ((source
                     (call-with-input-file
                         (car paths)
                       read-port-string)))
                (cons (car paths) source))))))

    ;; Return cached source-file/source pair for Agent library KEY.
    (define (agent-source-library-source-entry key)
      (let ((cached (assoc/equal key agent-source-library-source-cache)))
        (if cached
            (cdr cached)
            (let ((loaded (load-agent-source-library-source key)))
              (set! agent-source-library-source-cache
                    (cons (cons key loaded)
                          agent-source-library-source-cache))
              loaded))))

    ;; Return KEY's Agent library source text.
    (define (agent-source-library-source key)
      (cdr (agent-source-library-source-entry key)))

    ;; Return the single define-library form read from KEY's source file.
    (define (standard-source-library-form key)
      (let ((forms (agent-scheme-read-all
                    (standard-source-library-source key))))
        (if (not (= (length forms) 1))
            (eval-error
             "standard source library must contain exactly one form"
             key))
        (let* ((form (car forms))
               (parts (proper-list-elements
                       form
                       "standard source library")))
          (if (not (and (>= (length parts) 2)
                        (identifier-named? (car parts) 'define-library)
                        (equal? (second parts) key)))
              (eval-error
               "standard source library name does not match registry key"
               key))
          form)))

    ;; Return external export names declared by source library FORM.
    (define (standard-source-library-export-names form)
      (apply append
             (map
              (lambda (declaration)
                (if (form-named? declaration 'export)
                    (map cdr
                         (export-specs
                          (cdr
                           (proper-list-elements
                            declaration
                            "standard source export"))))
                    '()))
              (cddr
               (proper-list-elements form "standard source library")))))

    ;; Public metadata accessor for standard libraries backed by source files.
    (define (agent-scheme-standard-source-library-specs)
      (map
       (lambda (entry)
         (let* ((key (car entry))
                (source-entry (standard-source-library-source-entry key)))
           (list
            (list 'name key)
            (list 'exports
                  (standard-source-library-export-names
                   (standard-source-library-form key)))
            (list 'source-file (car source-entry)))))
       standard-source-library-load-paths))

    ;; Return the registered library for KEY in CONTEXT, or #f.
    (define (library-registry-ref context key)
      (let ((cell (assoc/equal key (context-libraries context))))
        (if cell (cdr cell) #f)))

    ;; Store LIBRARY under KEY in CONTEXT's registry.
    (define (library-registry-set! context key library)
      (let replace ((rest (context-libraries context)) (prefix '()))
        (cond
         ((null? rest)
          (set-context-libraries!
           context
           (cons (cons key library) (context-libraries context))))
         ((equal? key (caar rest))
          (set-context-libraries!
           context
           (append (reverse prefix)
                   (cons (cons key library) (cdr rest)))))
         (else
          (replace (cdr rest) (cons (car rest) prefix))))))

    ;; Return NAME's binding from SYNTAX-ENVIRONMENT's current frame only.
    (define (current-syntax-binding syntax-environment name)
      (let ((cell (assq name (syntax-environment-frame syntax-environment))))
        (if cell (cdr cell) #f)))

    ;; Report whether FORM is headed by identifier NAME.
    (define (form-named? form name)
      (and (pair? form) (identifier-named? (car form) name)))

    ;; Report whether FORM is an import declaration.
    (define (import-form? form)
      (form-named? form 'import))

    ;; Report whether FORM is a define-library declaration.
    (define (define-library-form? form)
      (form-named? form 'define-library))

    ;; Return BINDING under exported NAME while preserving its target object.
    (define (library-binding-with-name binding name)
      (make-library-binding
       name
       (library-binding-kind binding)
       (library-binding-object binding)
       (library-binding-library-key binding)))

    ;; Report whether two library bindings refer to the same exported object.
    (define (same-library-binding? left right)
      (and (library-binding? left)
           (library-binding? right)
           (eq? (library-binding-kind left) (library-binding-kind right))
           (eq? (library-binding-object left)
                (library-binding-object right))))

    ;; Snapshot current value and syntax frames as exports for LIBRARY-KEY.
    (define (snapshot-library-bindings value-environment syntax-environment
                                       library-key)
      (append
       (map (lambda (entry)
              (make-library-binding
               (car entry)
               'value
               (cdr entry)
               library-key))
            (environment-frame value-environment))
       (map (lambda (entry)
              (make-library-binding
               (car entry)
               'syntax
               (cdr entry)
               library-key))
            (syntax-environment-frame syntax-environment))))

    ;; Register `(scheme base)' from the active or freshly built base state.
    (define (register-scheme-base-library! context environment)
      (if (not (library-registry-ref context scheme-base-library-key))
          (let* ((use-current-environment?
                  (environment-cell environment '+))
                 (base-environment
                  (if use-current-environment?
                      environment
                      (agent-scheme-make-base-environment)))
                 (base-context
                  (if use-current-environment?
                      context
                      (new-eval-context '()))))
            (if (not use-current-environment?)
                (ensure-base-syntax! base-context base-environment))
            (let* ((base-syntax-environment
                    (context-syntax-environment base-context))
                   (exports
                    (snapshot-library-bindings
                     base-environment
                     base-syntax-environment
                     scheme-base-library-key)))
              (library-registry-set!
               context
               scheme-base-library-key
               (make-library
                scheme-base-library-key
                scheme-base-library-key
                exports
                base-environment
                base-syntax-environment))))))

    ;; Register an intentionally empty capability library for KEY.
    (define (register-empty-emacs-capability-library! key context)
      (if (not (library-registry-ref context key))
          (let ((value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment #f)))
            (library-registry-set!
             context
             key
             (make-library key key '() value-environment syntax-environment)))))

    ;; Read and evaluate a define-library form from SOURCE.
    (define (register-source-library! source context environment)
      (let ((forms (agent-scheme-read-all source)))
        (if (not (= (length forms) 1))
            (eval-error "source library must contain exactly one form"))
        (eval-define-library
         (car forms)
         environment
         context)))

    ;; Return NAME's binding from EXPORTS, or #f when absent.
    (define (find-library-export name exports)
      (cond
       ((null? exports) #f)
       ((eq? name (library-binding-name (car exports))) (car exports))
       (else (find-library-export name (cdr exports)))))

    ;; Register KEY as a subset of `(scheme base)' exports.
    (define (register-subset-library! key export-names context environment)
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (exports
                  (map
                   (lambda (name)
                     (or (find-library-export name base-exports)
                         (eval-error
                          "standard library binding is not available"
                          name)))
                   export-names)))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              exports
              (library-value-environment base-library)
              (library-syntax-environment base-library))))))

    ;; Register KEY as a library populated from primitive specs.
    (define (register-primitive-library! key primitive-specs context)
      (if (not (library-registry-ref context key))
          (let ((value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment #f)))
            (for-each
             (lambda (spec)
               (define-primitive!
                value-environment
                (car spec)
                (second spec)
                (third spec)
                (fourth spec)))
             primitive-specs)
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              (snapshot-library-bindings
               value-environment
               syntax-environment
               key)
              value-environment
              syntax-environment)))))

    ;; Return primitive specs for `(scheme char)'.
    (define (char-library-specs)
      (list
       (library-primitive-spec 'char-alphabetic? 'primitive-char-alphabetic? 1 1)
       (library-primitive-spec 'char-ci<=? 'primitive-char-ci<=? 2 #f)
       (library-primitive-spec 'char-ci<? 'primitive-char-ci<? 2 #f)
       (library-primitive-spec 'char-ci=? 'primitive-char-ci=? 2 #f)
       (library-primitive-spec 'char-ci>=? 'primitive-char-ci>=? 2 #f)
       (library-primitive-spec 'char-ci>? 'primitive-char-ci>? 2 #f)
       (library-primitive-spec 'char-downcase 'primitive-char-downcase 1 1)
       (library-primitive-spec 'char-foldcase 'primitive-char-foldcase 1 1)
       (library-primitive-spec 'char-lower-case? 'primitive-char-lower-case? 1 1)
       (library-primitive-spec 'char-numeric? 'primitive-char-numeric? 1 1)
       (library-primitive-spec 'char-upcase 'primitive-char-upcase 1 1)
       (library-primitive-spec 'char-upper-case? 'primitive-char-upper-case? 1 1)
       (library-primitive-spec 'char-whitespace? 'primitive-char-whitespace? 1 1)
       (library-primitive-spec 'digit-value 'primitive-digit-value 1 1)
       (library-primitive-spec 'string-ci<=? 'primitive-string-ci<=? 2 #f)
       (library-primitive-spec 'string-ci<? 'primitive-string-ci<? 2 #f)
       (library-primitive-spec 'string-ci=? 'primitive-string-ci=? 2 #f)
       (library-primitive-spec 'string-ci>=? 'primitive-string-ci>=? 2 #f)
       (library-primitive-spec 'string-ci>? 'primitive-string-ci>? 2 #f)
       (library-primitive-spec 'string-downcase 'primitive-string-downcase 1 1)
       (library-primitive-spec 'string-foldcase 'primitive-string-foldcase 1 1)
       (library-primitive-spec 'string-upcase 'primitive-string-upcase 1 1)))

    ;; Base-library cxr names re-exported by `(scheme cxr)'.
    (define cxr-library-base-names
      '(caar cadr cdar cddr))

    ;; Additional cxr names implemented directly by `(scheme cxr)'.
    (define cxr-library-extra-names
      '(caaar caadr cadar caddr cdaar cdadr cddar cdddr
        caaaar caaadr caadar caaddr cadaar cadadr caddar cadddr
        cdaaar cdaadr cdadar cdaddr cddaar cddadr cdddar cddddr))

    ;; Implement the `cxr-function` primitive with argument validation and
    ;; Agent Scheme values.
    (define (primitive-cxr-function name)
      (let ((text (symbol->string name)))
        (lambda (arguments context)
          (let loop ((index (- (string-length text) 2))
                     (value (car arguments)))
            (if (= index 0)
                value
                (let ((step (string-ref text index)))
                  (loop (- index 1)
                        (cond
                         ((char=? step #\a)
                          ((library-primitive-implementation 'primitive-car) (list value) context))
                         ((char=? step #\d)
                          ((library-primitive-implementation 'primitive-cdr) (list value) context))
                         (else
                          (eval-error "invalid cxr name" name))))))))))

    ;; Return primitive specs for generated cxr selectors.
    (define (cxr-library-specs)
      (map (lambda (name)
             (list name (primitive-cxr-function name) 1 1))
           cxr-library-extra-names))

    ;; Register `(scheme cxr)' from base selectors and generated selectors.
    (define (register-cxr-library! key context environment)
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (base-bindings
                  (map
                   (lambda (name)
                     (or (find-library-export name base-exports)
                         (eval-error
                          "standard library binding is not available"
                          name)))
                   cxr-library-base-names))
                 (value-environment (agent-scheme-make-empty-environment))
                 (syntax-environment (library-make-empty-syntax-environment #f)))
            (for-each
             (lambda (spec)
               (define-primitive!
                value-environment
                (car spec)
                (second spec)
                (third spec)
                (fourth spec)))
             (cxr-library-specs))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              (append
               base-bindings
               (snapshot-library-bindings
                value-environment
                syntax-environment
                key))
              value-environment
              syntax-environment)))))

    ;; Return primitive specs for `(scheme inexact)'.
    (define (inexact-library-specs)
      (list
       (library-primitive-spec 'acos 'primitive-acos 1 1)
       (library-primitive-spec 'asin 'primitive-asin 1 1)
       (library-primitive-spec 'atan 'primitive-atan 1 2)
       (library-primitive-spec 'cos 'primitive-cos 1 1)
       (library-primitive-spec 'exp 'primitive-exp 1 1)
       (library-primitive-spec 'finite? 'primitive-finite? 1 1)
       (library-primitive-spec 'infinite? 'primitive-infinite? 1 1)
       (library-primitive-spec 'log 'primitive-log 1 2)
       (library-primitive-spec 'nan? 'primitive-nan? 1 1)
       (library-primitive-spec 'sin 'primitive-sin 1 1)
       (library-primitive-spec 'sqrt 'primitive-sqrt 1 1)
       (library-primitive-spec 'tan 'primitive-tan 1 1)))

    ;; Return a primitive spec that always raises a policy-denied error.
    (define (policy-denied-spec name)
      (list name (library-policy-denied-primitive (symbol->string name)) 0 #f))

    ;; Register `(scheme r5rs)' with R5RS aliases for exact/inexact conversion.
    (define (register-r5rs-library! key context environment)
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (inexact-binding
                  (or (find-library-export 'inexact base-exports)
                      (eval-error "R5RS inexact alias missing")))
                 (exact-binding
                  (or (find-library-export 'exact base-exports)
                      (eval-error "R5RS exact alias missing")))
                 (exports
                  (append
                   base-exports
                   (list
                    (library-binding-with-name
                     inexact-binding
                     'exact->inexact)
                    (library-binding-with-name
                     exact-binding
                     'inexact->exact)))))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              exports
              (library-value-environment base-library)
              (library-syntax-environment base-library))))))

    ;; Register a supported standard library by KEY.
    (define (register-standard-library! key context environment)
      (cond
       ((equal? key '(scheme case-lambda))
        (register-source-library!
         (standard-source-library-source key)
         context
         environment))
       ((equal? key '(scheme char))
        (register-primitive-library!
         key
         (char-library-specs)
         context))
       ((equal? key '(scheme complex))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'angle 'primitive-angle 1 1)
          (library-primitive-spec 'imag-part 'primitive-imag-part 1 1)
          (library-primitive-spec 'magnitude 'primitive-magnitude 1 1)
          (library-primitive-spec 'make-polar 'primitive-make-polar 2 2)
          (library-primitive-spec 'make-rectangular 'primitive-make-rectangular 2 2)
          (library-primitive-spec 'real-part 'primitive-real-part 1 1))
         context))
       ((equal? key '(scheme cxr))
        (register-cxr-library! key context environment))
       ((equal? key '(scheme eval))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'environment 'primitive-environment 1 #f)
          (library-primitive-spec 'eval 'primitive-eval 2 2))
         context))
       ((equal? key '(scheme file))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'call-with-input-file
                                  'primitive-call-with-input-file 2 2)
          (library-primitive-spec 'call-with-output-file
                                  'primitive-call-with-output-file 2 2)
          (library-primitive-spec 'delete-file 'primitive-delete-file 1 1)
          (library-primitive-spec 'file-exists? 'primitive-file-exists? 1 1)
          (library-primitive-spec 'open-binary-input-file
                                  'primitive-open-binary-input-file 1 1)
          (library-primitive-spec 'open-binary-output-file
                                  'primitive-open-binary-output-file 1 1)
          (library-primitive-spec 'open-input-file
                                  'primitive-open-input-file 1 1)
          (library-primitive-spec 'open-output-file
                                  'primitive-open-output-file 1 1)
          (library-primitive-spec 'with-input-from-file
                                  'primitive-with-input-from-file 2 2)
          (library-primitive-spec 'with-output-to-file
                                  'primitive-with-output-to-file 2 2))
         context))
       ((equal? key '(scheme inexact))
        (register-primitive-library!
         key
         (inexact-library-specs)
         context))
       ((equal? key '(scheme lazy))
        (register-source-library!
         (standard-source-library-source key)
         context
         environment))
       ((equal? key '(scheme load))
        (register-primitive-library!
         key
         (list (library-primitive-spec 'load 'primitive-load 1 2))
         context))
       ((equal? key '(scheme process-context))
        (register-primitive-library!
         key
         (map policy-denied-spec
              '(command-line
                emergency-exit
                exit
                get-environment-variable
                get-environment-variables))
         context))
       ((equal? key '(scheme read))
        (register-primitive-library!
         key
         (list (library-primitive-spec 'read 'primitive-read 0 1))
         context))
       ((equal? key '(scheme repl))
        (register-primitive-library!
         key
         (list (policy-denied-spec 'interaction-environment))
         context))
       ((equal? key '(scheme r5rs))
        (register-r5rs-library! key context environment))
       ((equal? key '(scheme time))
        (register-primitive-library!
         key
         (map policy-denied-spec
              '(current-jiffy current-second jiffies-per-second))
         context))
       ((equal? key '(scheme write))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'display 'primitive-display 1 2)
          (library-primitive-spec 'write 'primitive-write 1 2)
          (library-primitive-spec 'write-shared 'primitive-write-shared 1 2)
          (library-primitive-spec 'write-simple 'primitive-write-simple 1 2))
         context))
       (else
        (eval-error "unknown standard library" key))))

    ;; Register a supported Agent Scheme interaction library by KEY.
    (define (register-agent-library! key context environment)
      (cond
       ((equal? key '(agent io))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'agent-yield 'primitive-agent-yield 1 1)
          (library-primitive-spec 'agent-log 'primitive-agent-log 2 #f)
          (library-primitive-spec 'agent-progress
                                  'primitive-agent-progress
                                  2
                                  2)
          (library-primitive-spec 'agent-warn 'primitive-agent-warn 1 #f)
          (library-primitive-spec 'agent-request
                                  'primitive-agent-request
                                  1
                                  1))
         context))
       ((equal? key '(agent approval))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'approval-request!
                                  'primitive-approval-request!
                                  1
                                  1)
          (library-primitive-spec 'approval-status
                                  'primitive-approval-status
                                  1
                                  1)
          (library-primitive-spec 'approval-cancel!
                                  'primitive-approval-cancel!
                                  1
                                  1)
          (library-primitive-spec 'approval-yield-pending
                                  'primitive-approval-yield-pending
                                  0
                                  0)
          (library-primitive-spec 'approval-resolve!
                                  'primitive-approval-resolve!
                                  2
                                  2))
         context))
       ((equal? key '(agent debugger))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'current-error 'primitive-current-error 0 0)
          (library-primitive-spec 'condition-stack
                                  'primitive-condition-stack
                                  1
                                  1)
          (library-primitive-spec 'condition-environment
                                  'primitive-condition-environment
                                  2
                                  2)
          (library-primitive-spec 'condition-restarts
                                  'primitive-condition-restarts
                                  1
                                  1)
          (library-primitive-spec 'restart-invoke!
                                  'primitive-restart-invoke!
                                  2
                                  2)
          (library-primitive-spec 'debugger-yield
                                  'primitive-debugger-yield
                                  1
                                  1))
         context))
       ((equal? key '(agent capability))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent diff))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent vcs))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent network))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent capability primitive))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'grant-capability!
                                  'primitive-grant-capability!
                                  1
                                  1)
          (library-primitive-spec 'current-grants
                                  'primitive-current-grants
                                  0
                                  0)
          (library-primitive-spec 'grant-ref
                                  'primitive-grant-ref
                                  1
                                  1)
          (library-primitive-spec 'grant-attenuate
                                  'primitive-grant-attenuate
                                  2
                                  2)
          (library-primitive-spec 'grant-revoke!
                                  'primitive-grant-revoke!
                                  1
                                  1)
          (library-primitive-spec 'call-with-capability-grant
                                  'primitive-call-with-capability-grant
                                  2
                                  2))
         context))
       ((equal? key '(agent memory))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'memory-put! 'primitive-memory-put! 3 3)
          (library-primitive-spec 'memory-ref 'primitive-memory-ref 2 2)
          (library-primitive-spec 'memory-delete!
                                  'primitive-memory-delete!
                                  2
                                  2)
          (library-primitive-spec 'memory-add! 'primitive-memory-add! 3 3)
          (library-primitive-spec 'memory-find 'primitive-memory-find 2 2)
          (library-primitive-spec 'memory-by-tag
                                  'primitive-memory-by-tag
                                  2
                                  2)
          (library-primitive-spec 'memory-recent
                                  'primitive-memory-recent
                                  2
                                  2)
          (library-primitive-spec 'memory-yield
                                  'primitive-memory-yield
                                  2
                                  2))
         context))
       ((equal? key '(agent redaction))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'secret-source?
                                  'primitive-secret-source?
                                  1
                                  1)
          (library-primitive-spec 'redact
                                  'primitive-redact
                                  2
                                  2)
          (library-primitive-spec 'context-local-only!
                                  'primitive-context-local-only!
                                  2
                                  2)
          (library-primitive-spec 'redaction-log
                                  'primitive-redaction-log
                                  0
                                  1)
          (library-primitive-spec 'safe-for-provider?
                                  'primitive-safe-for-provider?
                                  2
                                  2))
         context))
       (else
        (eval-error "unknown agent library" key))))

    ;; Report whether NAME is a known or already registered library.
    (define (library-available? name context environment)
      (let ((key (library-name-key name)))
        (or (equal? key scheme-base-library-key)
            (member key standard-library-keys)
            (member key agent-library-keys)
            (member key empty-emacs-capability-library-keys)
            (and (library-registry-ref context key) #t))))

    ;; Resolve NAME to a library, registering lazy standard libraries as needed.
    (define (resolve-library name context environment)
      (let ((key (library-name-key name)))
        (cond
         ((equal? key scheme-base-library-key)
          (register-scheme-base-library! context environment))
         ((member key standard-library-keys)
          (register-standard-library! key context environment))
         ((member key agent-library-keys)
          (register-agent-library! key context environment))
         ((member key empty-emacs-capability-library-keys)
          (register-empty-emacs-capability-library! key context)))
        (or (library-registry-ref context key)
            (eval-error "unknown library" key))))

    ;; Return NAME's import binding from BINDINGS, or #f.
    (define (find-import-binding name bindings)
      (cond
       ((null? bindings) #f)
       ((eq? name (library-binding-name (car bindings))) (car bindings))
       (else (find-import-binding name (cdr bindings)))))

    ;; Reject import modifiers naming exports that are absent from BINDINGS.
    (define (ensure-import-names-present names bindings description)
      (for-each
       (lambda (name)
         (if (not (find-import-binding name bindings))
             (eval-error
              (string-append description " import name not found")
              name)))
       names))

    ;; Merge duplicate compatible imports and reject conflicting imports.
    (define (ensure-compatible-import-bindings bindings)
      (let loop ((rest bindings) (seen '()) (result '()))
        (if (null? rest)
            (reverse result)
            (let* ((binding (car rest))
                   (name (library-binding-name binding))
                   (previous (assq name seen)))
              (cond
               ((not previous)
                (loop (cdr rest)
                      (cons (cons name binding) seen)
                      (cons binding result)))
               ((same-library-binding? (cdr previous) binding)
                (loop (cdr rest) seen result))
               (else
                (eval-error
                 "conflicting imports for identifier"
                 name)))))))

    ;; Validate import modifier operands as symbols.
    (define (import-modifier-identifiers forms description)
      (map (lambda (form) (expect-symbol form description)) forms))

    ;; Resolve an import set, applying only/except/prefix/rename modifiers.
    (define (resolve-import-set import-set context environment)
      (cond
       ((proper-library-name? import-set)
        (library-exports
         (resolve-library import-set context environment)))
       ((pair? import-set)
        (let* ((parts (proper-list-elements import-set "import set"))
               (operator (car parts)))
          (cond
           ((identifier-named? operator 'only)
            (if (< (length parts) 2)
                (eval-error "only import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (names
                    (import-modifier-identifiers (cddr parts) "only")))
              (ensure-import-names-present names bindings "only")
              (let loop ((rest bindings) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) (cons (car rest) result)))
                 (else (loop (cdr rest) result))))))
           ((identifier-named? operator 'except)
            (if (< (length parts) 2)
                (eval-error "except import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (names
                    (import-modifier-identifiers (cddr parts) "except")))
              (ensure-import-names-present names bindings "except")
              (let loop ((rest bindings) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) result))
                 (else (loop (cdr rest) (cons (car rest) result)))))))
           ((identifier-named? operator 'prefix)
            (if (not (= (length parts) 3))
                (eval-error
                 "prefix import set requires an import set and prefix"))
            (let ((prefix
                   (symbol->string
                    (expect-symbol (third parts) "prefix identifier"))))
              (map
               (lambda (binding)
                 (library-binding-with-name
                  binding
                  (string->symbol
                   (string-append
                    prefix
                    (symbol->string (library-binding-name binding))))))
               (resolve-import-set (second parts) context environment))))
           ((identifier-named? operator 'rename)
            (if (< (length parts) 2)
                (eval-error "rename import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (renames
                    (map
                     (lambda (rename-form)
                       (let ((rename-parts
                              (proper-list-elements
                               rename-form
                               "rename pair")))
                         (if (not (= (length rename-parts) 2))
                             (eval-error
                              "rename pair requires old and new identifiers"))
                         (cons
                          (expect-symbol
                           (car rename-parts)
                           "rename old identifier")
                          (expect-symbol
                           (second rename-parts)
                           "rename new identifier"))))
                     (cddr parts))))
              (ensure-import-names-present (map car renames)
                                           bindings
                                           "rename")
              (map
               (lambda (binding)
                 (let ((rename
                        (assq (library-binding-name binding) renames)))
                   (if rename
                       (library-binding-with-name binding (cdr rename))
                       binding)))
               bindings)))
           (else
            (eval-error "invalid import set" import-set)))))
       (else
        (eval-error "invalid import set" import-set))))

    ;; Install one imported value or syntax binding into the target frames.
    (define (install-imported-binding! binding value-environment
                                       syntax-environment)
      (let ((name (library-binding-name binding))
            (kind (library-binding-kind binding))
            (object (library-binding-object binding))
            (binding-library-key (library-binding-library-key binding)))
        (cond
         ((eq? kind 'value)
          (let ((existing (frame-cell value-environment name)))
            (cond
             ((not existing)
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((equal? binding-library-key scheme-base-library-key)
              ;; Repeated `(scheme base)' imports are common while source
              ;; libraries bootstrap; reinstalling the same base name is
              ;; harmless and keeps import-set handling small.
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((eq? existing object))
             (else
              (eval-error "conflicting import for identifier" name))))
          (if (not (memq name (environment-imported-names value-environment)))
              (set-environment-imported-names!
               value-environment
               (cons name (environment-imported-names value-environment)))))
         ((eq? kind 'syntax)
          (let ((existing (current-syntax-binding syntax-environment name)))
            (cond
             ((or (not existing)
                  (equal? binding-library-key scheme-base-library-key))
              (set-syntax-environment-frame!
               syntax-environment
               (cons (cons name object)
                     (syntax-environment-frame syntax-environment))))
             ((eq? existing object))
             (else
              (eval-error "conflicting syntax import for identifier" name))))
          (if (not (memq name
                         (syntax-environment-imported-names
                          syntax-environment)))
              (set-syntax-environment-imported-names!
               syntax-environment
               (cons name
                     (syntax-environment-imported-names
                      syntax-environment)))))
         (else
          (eval-error "unsupported library binding kind" kind)))))

    ;; Resolve IMPORT-SET and install all compatible imported bindings.
    (define (install-import-set! import-set value-environment
                                 syntax-environment context)
      (for-each
       (lambda (binding)
         (install-imported-binding! binding
                                    value-environment
                                    syntax-environment))
       (ensure-compatible-import-bindings
        (resolve-import-set import-set context value-environment))))

    ;; Evaluate an import declaration into the active value and syntax frames.
    (define (eval-import form environment context)
      (let ((parts (proper-list-elements form "import declaration")))
        (if (< (length parts) 2)
            (eval-error "import requires at least one import set"))
        (for-each
         (lambda (import-set)
           (install-import-set!
            import-set
            environment
            (context-syntax-environment context)
            context))
         (cdr parts))
        agent-scheme-unspecified))

    ;; Parse export clauses into internal-name/external-name pairs.
    (define (export-specs forms)
      (let loop ((rest forms) (specs '()))
        (if (null? rest)
            (reverse specs)
            (let ((form (car rest)))
              (cond
               ((identifier-datum? form)
                (let ((name (expect-symbol form "export identifier")))
                  (loop (cdr rest) (cons (cons name name) specs))))
               ((form-named? form 'rename)
                (let ((parts (proper-list-elements form "export rename")))
                  (if (not (= (length parts) 3))
                      (eval-error
                       "export rename requires internal and external identifiers"))
                  (loop
                   (cdr rest)
                   (cons
                    (cons
                     (expect-symbol
                      (second parts)
                      "export internal identifier")
                     (expect-symbol
                      (third parts)
                      "export external identifier"))
                    specs))))
               (else
                (eval-error "invalid export spec" form)))))))

    ;; Report whether a cond-expand feature requirement is satisfied.
    (define (feature-requirement-satisfied? requirement context environment)
      (cond
       ((identifier-datum? requirement)
        (eq? (identifier-datum-name requirement) 'r7rs))
       ((pair? requirement)
        (let* ((parts (proper-list-elements requirement "feature requirement"))
               (operator (car parts)))
          (cond
           ((identifier-named? operator 'library)
            (if (not (= (length parts) 2))
                (eval-error
                 "library feature requirement requires one library name"))
            (library-available? (second parts) context environment))
           ((identifier-named? operator 'and)
            (let loop ((rest (cdr parts)))
              (or (null? rest)
                  (and (feature-requirement-satisfied?
                        (car rest)
                        context
                        environment)
                       (loop (cdr rest))))))
           ((identifier-named? operator 'or)
            (let loop ((rest (cdr parts)))
              (and (not (null? rest))
                   (or (feature-requirement-satisfied?
                        (car rest)
                        context
                        environment)
                       (loop (cdr rest))))))
           ((identifier-named? operator 'not)
            (if (not (= (length parts) 2))
                (eval-error
                 "not feature requirement requires one nested requirement"))
            (not
             (feature-requirement-satisfied?
              (second parts)
              context
              environment)))
           (else #f))))
       (else #f)))

    ;; Select declarations from the first satisfied library cond-expand clause.
    (define (expand-library-cond-expand clauses context environment)
      (let loop ((rest clauses))
        (if (null? rest)
            (eval-error "unfulfilled library cond-expand")
            (let* ((parts (proper-list-elements
                           (car rest)
                           "cond-expand clause"))
                   (requirement (car parts)))
              (if (or (identifier-named? requirement 'else)
                      (feature-requirement-satisfied?
                       requirement context environment))
                  (cdr parts)
                  (loop (cdr rest)))))))

    ;; Expand library declaration wrappers such as cond-expand and includes.
    (define (expand-library-declaration declaration context environment)
      (cond
       ((form-named? declaration 'cond-expand)
        (apply append
               (map
                (lambda (nested)
                  (expand-library-declaration nested context environment))
                (expand-library-cond-expand
                 (cdr (proper-list-elements
                       declaration
                       "library cond-expand"))
                 context
                 environment))))
       ((form-named? declaration 'include-library-declarations)
        (expand-include-library-declarations
         declaration
         context
         environment))
       (else
        (list declaration))))

    ;; Return string literal filenames from an include-style declaration.
    (define (include-filenames declaration)
      (let* ((parts (proper-list-elements declaration "include declaration"))
             (operator (identifier-datum-name (car parts))))
        (if (null? (cdr parts))
            (eval-error "include requires at least one filename" operator))
        (map
         (lambda (filename)
           (if (not (string? filename))
               (eval-error "include filename must be a string literal"
                           operator))
           filename)
         (cdr parts))))

    ;; Test whether TEXT begins with PREFIX.
    (define (string-prefix? prefix string)
      (let ((prefix-length (string-length prefix))
            (string-length-value (string-length string)))
        (and (<= prefix-length string-length-value)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref string index))
                        (loop (+ index 1))))))))

    ;; Remove a single trailing slash from PATH for policy-prefix checks.
    (define (strip-trailing-slash path)
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    ;; Report whether PATH is exactly allowed or inside an allowed directory.
    (define (path-policy-allows-file? path allowed-paths)
      (let loop ((rest allowed-paths))
        (and (not (null? rest))
             (let* ((allowed (strip-trailing-slash (car rest)))
                    (allowed-directory (string-append allowed "/")))
               (or (string=? path allowed)
                   (string-prefix? allowed-directory path)
                   (loop (cdr rest)))))))

    ;; Report whether PATH satisfies the current include allow-list policy.
    (define (include-policy-allows-file? path context)
      (path-policy-allows-file? path (context-include-paths context)))

    ;; Resolve FILENAME against the include directory and enforce file policy.
    (define (resolve-include-file filename context operation binding)
      (let* ((authorization
              (authorize-file-capability
               filename
               context
               operation
               binding
               (context-include-paths context)))
             (path (file-authorization-path authorization)))
        (if (not (file-exists? path))
            (begin
              (audit-file-capability-result!
               context
               authorization
               "include file is not readable"
               #t)
              (eval-error "include file is not readable" filename)))
        (audit-file-capability-result! context authorization 'read #f)
        path))

    ;; Return PATH's directory component without the trailing slash.
    (define (path-directory path)
      (let loop ((index (- (string-length path) 1)))
        (cond
         ((< index 0) "")
         ((char=? (string-ref path index) #\/)
          (substring path 0 index))
         (else (loop (- index 1))))))

    ;; Read PATH into a string using the Scheme file API.
    (define (read-file-string path)
      (call-with-input-file
       path
       (lambda (port)
         (let loop ((chars '()))
           (let ((char (read-char port)))
             (if (eof-object? char)
                 (list->string (reverse chars))
                 (loop (cons char chars))))))))

    ;; Run THUNK with CONTEXT's include directory temporarily set.
    (define (with-include-directory context directory thunk)
      (let ((previous-directory (context-include-directory context)))
        (dynamic-wind
          (lambda ()
            (set-context-include-directory!
             context
             (normalize-include-directory directory)))
          thunk
          (lambda ()
            (set-context-include-directory!
             context
             previous-directory)))))

    ;; Read and parse all forms from an include file, returning forms and
    ;; directory.
    (define (read-include-file-forms filename context fold-case? operation)
      (let* ((path (resolve-include-file
                    filename
                    context
                    operation
                    (if (eq? operation 'include-ci)
                        "include-ci"
                        (if (eq? operation 'library-source)
                            "include-library-declarations"
                            "include"))))
             (source (read-file-string path)))
        (cons
         (agent-scheme-read-all
          (if fold-case?
              (string-append "#!fold-case\n" source)
              source))
         (path-directory path))))

    ;; Return all body forms read by an include or include-ci declaration.
    (define (library-include-body-forms declaration context fold-case?)
      (apply append
             (map (lambda (filename)
                    (car (read-include-file-forms
                          filename
                          context
                          fold-case?
                          (if fold-case? 'include-ci 'include))))
                  (include-filenames declaration))))

    ;; Read include-library-declarations files and expand their declarations.
    (define (expand-include-library-declarations declaration context
                                                 environment)
      (apply
       append
       (map
        (lambda (filename)
          (let* ((read-result
                  (read-include-file-forms
                   filename
                   context
                   #f
                   'library-source))
                 (forms (car read-result))
                 (directory (cdr read-result)))
            (with-include-directory
             context
             directory
             (lambda ()
               (apply
                append
                (map
                 (lambda (nested)
                   (expand-library-declaration
                    nested
                    context
                    environment))
                 forms))))))
        (include-filenames declaration))))

    ;; Resolve one export spec to a value or syntax library binding.
    (define (library-export-binding spec library-key value-environment
                                    syntax-environment)
      (let* ((internal-name (car spec))
             (external-name (cdr spec))
             (cell (environment-cell value-environment internal-name))
             (syntax-binding
              (library-syntax-environment-ref syntax-environment internal-name)))
        (cond
         ((and cell syntax-binding)
          (eval-error
           "export identifier has both value and syntax bindings"
           internal-name))
         (cell
          (make-library-binding external-name 'value cell library-key))
         (syntax-binding
          (make-library-binding external-name
                                'syntax
                                syntax-binding
                                library-key))
         (else
          (eval-error "exported identifier is not bound" internal-name)))))

    ;; Build checked library exports from parsed export specs.
    (define (library-exports-from-specs specs library-key value-environment
                                        syntax-environment)
      (ensure-distinct-names (map cdr specs) "library exports")
      (ensure-compatible-import-bindings
       (map (lambda (spec)
              (library-export-binding spec
                                      library-key
                                      value-environment
                                      syntax-environment))
            specs)))

    ;; Evaluate library body forms under the library syntax environment.
    (define (eval-library-begin forms value-environment
                                syntax-environment context)
      (library-with-syntax-environment
       context
       syntax-environment
       (lambda ()
         (library-trampoline
          (make-sequence forms #t)
          value-environment
          context))))

    ;; Evaluate a define-library form and register its exported bindings.
    (define (eval-define-library form environment context)
      (let ((parts (proper-list-elements form "define-library form")))
        (if (< (length parts) 2)
            (eval-error "define-library requires a library name"))
        (let ((name (second parts)))
          (if (not (proper-library-name? name))
              (eval-error "invalid library name" name))
          (let ((library-key (library-name-key name))
                (value-environment (agent-scheme-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment #f)))
            (let loop ((raw-declarations (cddr parts))
                       (export-spec-list '()))
              (if (null? raw-declarations)
                  (begin
                    (library-registry-set!
                     context
                     library-key
                     (make-library
                      name
                      library-key
                      (library-exports-from-specs
                       export-spec-list
                       library-key
                       value-environment
                       syntax-environment)
                      value-environment
                      syntax-environment))
                    agent-scheme-unspecified)
                  (let declaration-loop
                      ((declarations
                        (expand-library-declaration
                         (car raw-declarations)
                         context
                         environment))
                       (exports export-spec-list))
                    (if (null? declarations)
                        (loop (cdr raw-declarations) exports)
                        (let* ((declaration (car declarations))
                               (declaration-parts
                                (proper-list-elements
                                 declaration
                                 "library declaration"))
                               (operator (car declaration-parts)))
                          ;; `cond-expand' and include-library-declarations are
                          ;; flattened before this dispatch; only core library
                          ;; declarations should reach this point.
                          (cond
                           ((identifier-named? operator 'export)
                            (declaration-loop
                             (cdr declarations)
                             (append exports
                                     (export-specs
                                      (cdr declaration-parts)))))
                           ((identifier-named? operator 'import)
                            (library-with-syntax-environment
                             context
                             syntax-environment
                             (lambda ()
                               (eval-import declaration
                                            value-environment
                                            context)))
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'begin)
                            (eval-library-begin
                             (cdr declaration-parts)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'include)
                            (eval-library-begin
                             (library-include-body-forms
                              declaration
                              context
                              #f)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'include-ci)
                            (eval-library-begin
                             (library-include-body-forms
                              declaration
                              context
                              #t)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named?
                             operator
                             'include-library-declarations)
                            (eval-error
                             "include-library-declarations must expand before evaluation"
                             operator))
                           (else
                            (eval-error
                             "unsupported library declaration"
                             declaration))))))))))))

    ))
