;;; Portable Consent Scheme library resolver support.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns source-library discovery, import-set resolution, and
;;; define-library evaluation without importing the evaluator module.

(define-library (consent library)
  (export consent-standard-source-library-specs
          consent-stdlib-source-library-specs
          consent-runtime-source-files
          consent-install-library-backend!
          consent-apply-callable
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
          (consent reader)
          (consent runtime)
          (consent base))
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

    (define (consent-install-library-backend!
             primitive-resolver policy-denied trampoline
             make-empty-syntax-environment syntax-environment-ref
             with-syntax-environment)
      "Install interpreter and macro callbacks used by library resolution."
      #((parameters
         (primitive-resolver
          . ("Callback mapping a primitive identifier to its"
             "implementation."))
         (policy-denied (type procedure)
          (description
           ("Factory building a policy-denied primitive from a"
             "description.")))
         (trampoline (type procedure)
          (description
           ("Callback evaluating a library body sequence in an"
             "environment and context.")))
         (make-empty-syntax-environment (type procedure)
          (description
           ("Callback constructing a fresh syntax environment under a"
             "parent.")))
         (syntax-environment-ref (type procedure)
          (description "Callback looking up a name in a syntax environment."))
         (with-syntax-environment (type procedure)
          (description
           ("Callback running a thunk with a syntax environment"
             "installed in a context."))))
        (returns . ("The unspecified value after storing every backend hook."))
        (effects state-write))
      (set! library-primitive-resolver primitive-resolver)
      (set! library-policy-denied-primitive policy-denied)
      (set! library-trampoline trampoline)
      (set! library-make-empty-syntax-environment make-empty-syntax-environment)
      (set! library-syntax-environment-ref syntax-environment-ref)
      (set! library-with-syntax-environment with-syntax-environment)
      consent-unspecified)

    (define (library-primitive-implementation name)
      "Resolve a primitive implementation identifier through the backend."
      (library-primitive-resolver name))

    (define (library-primitive-spec name implementation minimum maximum)
      "Construct a primitive spec from a backend implementation identifier."
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

    ;; stdlib library keys recognized by the portable registry.
    (define stdlib-source-library-keys
      '((stdlib manifest)
        (stdlib and-let-star)
        (stdlib comparator)
        (stdlib json)))

    ;; Registry aliases can expose a target library directly or as a subset.
    (define stdlib-library-aliases
      '(((alias . (srfi manifest))
         (target . (stdlib manifest)))
        ((alias . (srfi 16))
         (target . (scheme case-lambda)))
        ((alias . (srfi srfi-16))
         (target . (scheme case-lambda)))
        ((alias . (srfi 2))
         (target . (stdlib and-let-star)))
        ((alias . (srfi srfi-2))
         (target . (stdlib and-let-star)))
        ((alias . (consent json))
         (target . (stdlib json)))
        ((alias . (srfi 180))
         (target . (stdlib json)))
        ((alias . (srfi srfi-180))
         (target . (stdlib json)))
        ((alias . (scheme comparator))
         (target . (stdlib comparator)))
        ((alias . (srfi 128))
         (target . (stdlib comparator)))
        ((alias . (srfi srfi-128))
         (target . (stdlib comparator)))
        ((alias . (stdlib json read))
         (target . (stdlib json))
         (exports json-number-of-character-limit
                  json-nesting-depth-limit
                  json-null?
                  json-error?
                  json-error-reason
                  json-fold
                  json-generator
                  json-read
                  json-lines-read
                  json-sequence-read))
        ((alias . (consent json read))
         (target . (stdlib json))
         (exports json-number-of-character-limit
                  json-nesting-depth-limit
                  json-null?
                  json-error?
                  json-error-reason
                  json-fold
                  json-generator
                  json-read
                  json-lines-read
                  json-sequence-read))))

    ;; Alias specs are alists so new optional fields remain backwards-compatible.
    (define (library-alias-field spec field)
      "Return FIELD from alias SPEC, or #f when absent."
      (let ((entry (assq field spec)))
        (if entry (cdr entry) #f)))

    ;; Recognized stdlib names include concrete source libraries and aliases.
    (define stdlib-library-keys
      (append stdlib-source-library-keys
              (map (lambda (alias) (library-alias-field alias 'alias))
                   stdlib-library-aliases)))

    ;; Agent interaction library keys recognized by the portable registry.
    (define agent-library-keys
      '((agent io)
        (agent approval)
        (agent debugger)
        (agent helper)
        (agent job)
        (agent test)
        (agent diagnostics)
        (agent diff)
        (agent vcs)
        (agent network)
        (agent test primitive)
        (agent task)
        (agent memory)
        (agent plan)
        (agent models)
        (agent models primitive)
        (agent context)
        (agent reflect)
        (agent redaction)
        (agent session)
        (agent registry)
        (agent proposal)
        (agent runner)
        (agent reliability)
        (agent prompt)
        (agent transcript)))

    ;; Consent core library keys recognized by the portable registry.  The
    ;; capability libraries are first-class consent primitives: a capability is
    ;; the encoded act of consent, so it belongs in the consent core rather than
    ;; the agent domain it governs.
    (define consent-library-keys
      '((consent capability)
        (consent capability primitive)))

    ;; Checked-in Consent Scheme source libraries loaded by the portable
    ;; evaluator when a public agent library needs syntax definitions.
    (define agent-source-library-load-paths
      '(((agent diagnostics)
         "scheme/agent/diagnostics.sld"
         "agent/diagnostics.sld")
        ((agent diff)
         "scheme/agent/diff.sld"
         "agent/diff.sld")
        ((agent vcs)
         "scheme/agent/vcs.sld"
         "agent/vcs.sld")
        ((agent network)
         "scheme/agent/network.sld"
         "agent/network.sld")
        ((agent models)
         "scheme/agent/models.sld"
         "agent/models.sld")
        ((agent registry)
         "scheme/agent/registry.sld"
         "agent/registry.sld")
        ((agent proposal)
         "scheme/agent/proposal.sld"
         "agent/proposal.sld")
        ((agent runner)
         "scheme/agent/runner.sld"
         "agent/runner.sld")
        ((agent reliability)
         "scheme/agent/reliability.sld"
         "agent/reliability.sld")
        ((agent prompt)
         "scheme/agent/prompt.sld"
         "agent/prompt.sld")
        ((agent task)
         "scheme/agent/task.sld"
         "agent/task.sld")
        ((agent test)
         "scheme/agent/test.sld"
         "agent/test.sld")
        ((agent transcript)
         "scheme/agent/transcript.sld"
         "agent/transcript.sld")))

    ;; Agent model libraries used by runtime internals. Ordinary user imports
    ;; of the same public names resolve to primitive libraries; the source
    ;; model is exposed only under the internal-libraries host posture.
    (define agent-internal-source-library-load-paths
      '(((agent approval)
         "scheme/agent/approval.sld"
         "agent/approval.sld")
        ((agent context)
         "scheme/agent/context.sld"
         "agent/context.sld")
        ((agent helper)
         "scheme/agent/helper.sld"
         "agent/helper.sld")
        ((agent job)
         "scheme/agent/job.sld"
         "agent/job.sld")
        ((agent memory)
         "scheme/agent/memory.sld"
         "agent/memory.sld")
        ((agent plan)
         "scheme/agent/plan.sld"
         "agent/plan.sld")
        ((agent redaction)
         "scheme/agent/redaction.sld"
         "agent/redaction.sld")
        ((agent session)
         "scheme/agent/session.sld"
         "agent/session.sld")))

    ;; Checked-in consent core source libraries loaded as portable Scheme
    ;; source files.
    (define consent-source-library-load-paths
      '(((consent capability)
         "scheme/consent/capability.sld"
         "consent/capability.sld")))

    ;; Checked-in standard libraries loaded as portable Scheme source files.
    (define standard-source-library-load-paths
      '(((scheme case-lambda)
         "scheme/consent/case-lambda.sld"
         "consent/case-lambda.sld")
        ((scheme lazy)
         "scheme/consent/lazy.sld"
         "consent/lazy.sld")))

    ;; Checked-in optional stdlib libraries loaded as portable
    ;; Scheme source files.
    (define stdlib-source-library-load-paths
      '(((stdlib manifest)
         "scheme/stdlib/manifest.sld"
         "stdlib/manifest.sld")
        ((stdlib and-let-star)
         "scheme/stdlib/and-let-star.sld"
         "stdlib/and-let-star.sld")
        ((stdlib comparator)
         "scheme/stdlib/comparator.sld"
         "stdlib/comparator.sld")
        ((stdlib json)
         "scheme/stdlib/json.sld"
         "stdlib/json.sld")))

    ;; Cache selected source path and contents by standard library key.
    (define standard-source-library-source-cache '())

    ;; Cache selected source path and contents by stdlib library key.
    (define stdlib-source-library-source-cache '())

    ;; Cache selected source path and contents by Agent library key.
    (define agent-source-library-source-cache '())

    (define (proper-list-elements/maybe datum)
      "Return DATUM's list elements, or #f when DATUM is not a proper list."
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else #f))))

    (define (proper-library-name? datum)
      "Report whether DATUM is a proper R7RS library name."
      (and (pair? datum)
           (let ((parts (proper-list-elements/maybe datum)))
             (and parts
                  (let loop ((rest parts))
                    (cond
                     ((null? rest) #t)
                     ((or (symbol? (car rest))
                          (and (integer? (car rest))
                               (exact? (car rest))
                               (>= (car rest) 0))
                          (and (consent-number? (car rest))
                               (eq? (consent-number-kind (car rest))
                                    'integer)
                               (eq? (consent-number-exactness (car rest))
                                    'exact)
                               (>= (consent-number-value (car rest)) 0)))
                      (loop (cdr rest)))
                     (else #f)))))))

    (define (library-name-part-key part)
      "Return PART normalized for registry-key comparison."
      (if (consent-number? part)
          (consent-number-value part)
          part))

    (define (library-name-key name)
      "Validate and return NAME as a library registry key."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Candidate R7RS library name to validate.")))
        (returns (type (list-of (or symbol exact-integer)))
         (description "NAME unchanged when it is a proper library name."))
        (effects error))
      (if (proper-library-name? name)
          (map library-name-part-key name)
          (eval-error "invalid library name" name)))

    (define (assoc/equal key alist)
      "Search ALIST for KEY using equal? comparison."
      (cond
       ((null? alist) #f)
       ((equal? key (caar alist)) (car alist))
       (else (assoc/equal key (cdr alist)))))

    (define (standard-source-library-paths key)
      "Return the configured path candidates for source-backed standard library KEY."
      (let ((entry (assoc/equal key standard-source-library-load-paths)))
        (if entry
            (cdr entry)
            (eval-error "standard source library is not available" key))))

    (define (stdlib-source-library-paths key)
      "Return configured path candidates for source-backed stdlib library KEY."
      (let ((entry (assoc/equal key stdlib-source-library-load-paths)))
        (if entry
            (cdr entry)
            (eval-error "stdlib source library is not available" key))))

    (define (source-library-relative-path paths)
      "Return the canonical datadir/embedded-relative path for a source"
      "library: the last (most-relative) configured candidate."
      (if (null? (cdr paths))
          (car paths)
          (source-library-relative-path (cdr paths))))

    (define (consent-runtime-source-files)
      "Return the canonical relative paths of every runtime-provided"
      "source file the interpreter loads as data: the base prelude and"
      "syntax prelude, then the standard, agent, and consent"
      "source-libraries."
      "This is the single source of truth the host-compiled staging"
      "extracts its embed and install manifest from, so the build never"
      "hand-maintains a parallel list."
      #((parameters)
        (returns (type list)
         (description
          ("A list of canonical relative source-file paths the runtime"
            "loads as data.")))
        (effects pure))
      (append
       (list (source-library-relative-path consent-base-prelude-load-paths)
             (source-library-relative-path consent-base-syntax-load-paths))
       (map (lambda (entry) (source-library-relative-path (cdr entry)))
            standard-source-library-load-paths)
       (map (lambda (entry) (source-library-relative-path (cdr entry)))
            stdlib-source-library-load-paths)
       (map (lambda (entry) (source-library-relative-path (cdr entry)))
            agent-internal-source-library-load-paths)
       (map (lambda (entry) (source-library-relative-path (cdr entry)))
            agent-source-library-load-paths)
       (map (lambda (entry) (source-library-relative-path (cdr entry)))
            consent-source-library-load-paths)))

    (define (load-standard-source-library-source key)
      "Read KEY's source through the host/core resolution contract (search"
      "dirs, source tree, embedded)."
      (let* ((paths (standard-source-library-paths key))
             (relative (source-library-relative-path paths))
             (entry (resolve-source-entry relative paths)))
        (if entry
            entry
            (eval-error "unable to load standard source library" key))))

    (define (standard-source-library-source-entry key)
      "Return cached source-file/source pair for source-backed standard library KEY."
      (let ((cached (assoc/equal key standard-source-library-source-cache)))
        (if cached
            (cdr cached)
            (let ((loaded (load-standard-source-library-source key)))
              (set! standard-source-library-source-cache
                    (cons (cons key loaded)
                          standard-source-library-source-cache))
              loaded))))

    (define (standard-source-library-source key)
      "Return KEY's portable source text."
      (cdr (standard-source-library-source-entry key)))

    (define (load-stdlib-source-library-source key)
      "Read stdlib library KEY's source through the host/core resolution"
      "contract (search dirs, source tree, embedded)."
      (let* ((paths (stdlib-source-library-paths key))
             (relative (source-library-relative-path paths))
             (entry (resolve-source-entry relative paths)))
        (if entry
            entry
            (eval-error "unable to load stdlib source library" key))))

    (define (stdlib-source-library-source-entry key)
      "Return cached source-file/source pair for stdlib library KEY."
      (let ((cached (assoc/equal key stdlib-source-library-source-cache)))
        (if cached
            (cdr cached)
            (let ((loaded (load-stdlib-source-library-source key)))
              (set! stdlib-source-library-source-cache
                    (cons (cons key loaded)
                          stdlib-source-library-source-cache))
              loaded))))

    (define (stdlib-source-library-source key)
      "Return KEY's stdlib library source text."
      (cdr (stdlib-source-library-source-entry key)))

    (define (agent-source-library-paths key)
      "Return configured source path candidates for agent or consent KEY."
      (let ((entry (or (assoc/equal key agent-source-library-load-paths)
                       (assoc/equal key consent-source-library-load-paths))))
        (if entry
            (cdr entry)
            (eval-error "source library is not available" key))))

    (define (load-agent-source-library-source key)
      "Read Agent library KEY's source through the host/core resolution"
      "contract (search dirs, source tree, embedded)."
      (let* ((paths (agent-source-library-paths key))
             (relative (source-library-relative-path paths))
             (entry (resolve-source-entry relative paths)))
        (if entry
            entry
            (eval-error "unable to load agent source library" key))))

    (define (agent-source-library-source-entry key)
      "Return cached source-file/source pair for Agent library KEY."
      (let ((cached (assoc/equal key agent-source-library-source-cache)))
        (if cached
            (cdr cached)
            (let ((loaded (load-agent-source-library-source key)))
              (set! agent-source-library-source-cache
                    (cons (cons key loaded)
                          agent-source-library-source-cache))
              loaded))))

    (define (agent-source-library-source key)
      "Return KEY's Agent library source text."
      (cdr (agent-source-library-source-entry key)))

    (define (source-library-form key source description)
      "Return the single define-library form read from SOURCE for KEY."
      (let ((forms (consent-read-all source)))
        (if (not (= (length forms) 1))
            (eval-error
             (string-append description " must contain exactly one form")
             key))
        (let* ((form (car forms))
               (parts (proper-list-elements
                       form
                       description)))
          (if (not (and (>= (length parts) 2)
                        (identifier-named? (car parts) 'define-library)
                        (equal? (library-name-key (second parts)) key)))
              (eval-error
               (string-append description " name does not match registry key")
               key))
          form)))

    (define (standard-source-library-form key)
      "Return the single define-library form read from KEY's source file."
      (source-library-form
       key
       (standard-source-library-source key)
       "standard source library"))

    (define (standard-source-library-export-names form)
      "Return external export names declared by source library FORM."
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

    (define (consent-standard-source-library-specs)
      "Public metadata accessor for standard libraries backed by source files."
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed standard library.")))
        (effects state-read state-write))
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

    (define (consent-stdlib-source-library-specs)
      "Public metadata accessor for stdlib libraries backed by source files."
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed stdlib library.")))
        (effects state-read state-write))
      (map
       (lambda (entry)
         (let* ((key (car entry))
                (source-entry (stdlib-source-library-source-entry key)))
           (list
            (list 'name key)
            (list 'exports
                  (standard-source-library-export-names
                   (source-library-form
                    key
                    (stdlib-source-library-source key)
                    "stdlib source library")))
            (list 'source-file (car source-entry)))))
       stdlib-source-library-load-paths))

    (define (library-registry-ref context key)
      "Return the registered library for KEY in CONTEXT, or #f."
      #((parameters
         (context (type eval-context)
          (description ("Evaluation context whose library registry is searched.")))
         (key (type list)
          (description "Library registry key to look up.")))
        (returns (type (or library boolean))
         (description "The library registered under KEY, or #f when it is absent."))
        (effects state-read))
      (let ((cell (assoc/equal key (context-libraries context))))
        (if cell (cdr cell) #f)))

    (define (library-registry-set! context key library)
      "Store LIBRARY under KEY in CONTEXT's registry."
      #((parameters
         (context (type eval-context)
          (description ("Evaluation context whose library registry is updated.")))
         (key (type list)
          (description "Library registry key to associate with LIBRARY."))
         (library (type library)
          (description "Library object to store under KEY.")))
        (returns . ("An unspecified value after registering LIBRARY under KEY."))
        (effects state-write))
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

    (define (current-syntax-binding syntax-environment name)
      "Return NAME's binding from SYNTAX-ENVIRONMENT's current frame only."
      (let ((cell (assq name (syntax-environment-frame syntax-environment))))
        (if cell (cdr cell) #f)))

    (define (form-named? form name)
      "Report whether FORM is headed by identifier NAME."
      #((parameters
         (form . "Datum to test for a heading identifier.")
         (name (type symbol)
          (description "Symbol the form's head identifier must match.")))
        (returns (type boolean)
         (description
          ("#t when FORM is a pair whose head identifier is NAME, else"
            "#f.")))
        (effects pure))
      (and (pair? form) (identifier-named? (car form) name)))

    (define (import-form? form)
      "Report whether FORM is an import declaration."
      #((parameters
         (form . "Datum to test for an import declaration heading."))
        (returns (type boolean)
         (description ("#t when FORM is headed by the import identifier, else #f.")))
        (effects pure))
      (form-named? form 'import))

    (define (define-library-form? form)
      "Report whether FORM is a define-library declaration."
      #((parameters
         (form . ("Datum to test for a define-library declaration heading.")))
        (returns (type boolean)
         (description
          ("#t when FORM is headed by the define-library identifier,"
            "else #f.")))
        (effects pure))
      (form-named? form 'define-library))

    (define (library-binding-with-name binding name)
      "Return BINDING under exported NAME while preserving its target object."
      (make-library-binding
       name
       (library-binding-kind binding)
       (library-binding-object binding)
       (library-binding-library-key binding)))

    (define (same-library-binding? left right)
      "Report whether two library bindings refer to the same exported object."
      (and (library-binding? left)
           (library-binding? right)
           (eq? (library-binding-kind left) (library-binding-kind right))
           (eq? (library-binding-object left)
                (library-binding-object right))))

    (define (snapshot-library-bindings value-environment syntax-environment
                                       library-key)
      "Snapshot current value and syntax frames as exports for LIBRARY-KEY."
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

    (define (register-scheme-base-library! context environment)
      "Register `(scheme base)' from the active or freshly built base state."
      (if (not (library-registry-ref context scheme-base-library-key))
          (let* ((use-current-environment?
                  (environment-cell environment '+))
                 (base-environment
                  (if use-current-environment?
                      environment
                      (consent-make-base-environment)))
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

    (define (register-empty-emacs-capability-library! key context)
      "Register an intentionally empty capability library for KEY."
      (if (not (library-registry-ref context key))
          (let ((value-environment (consent-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment #f)))
            (library-registry-set!
             context
             key
             (make-library key key '() value-environment syntax-environment)))))

    (define (register-source-library! source context environment)
      "Read and evaluate a define-library form from SOURCE."
      (let ((forms (consent-read-all source)))
        (if (not (= (length forms) 1))
            (eval-error "source library must contain exactly one form"))
        (eval-define-library
         (car forms)
         environment
         context)))

    ;; Host posture: any internal `(consent X)' / `(cli X)' / `(agent X)'
    ;; library can be loaded as a source library so a trusted program can
    ;; import the runtime's own implementation. This is the capability that
    ;; lets the compiled runtime act as a full Scheme host for the portable
    ;; white-box tests (self-hosting). Public agent primitive libraries keep
    ;; their ordinary grant-independent resolution paths, while the source
    ;; model libraries used by runtime internals resolve through this gate.
    (define (host-library-key? key)
      "Report whether KEY names a runtime-internal source library exposable"
      "under the host posture."
      (and (pair? key)
           (or (memq (car key) '(consent cli))
               (and (eq? (car key) 'agent)
                    (or (assoc/equal key agent-internal-source-library-load-paths)
                        (and (not (member key agent-library-keys))
                             (not (assoc/equal key agent-source-library-load-paths))))))
           (not (member key consent-library-keys))
           (not (equal? key scheme-base-library-key))))

    (define (host-library-relative-path key)
      "Return the datadir/source-relative path for host library KEY: (consent"
      "reader) -> consent/reader.sld."
      (let loop ((parts key) (acc ""))
        (if (null? (cdr parts))
            (string-append acc (symbol->string (car parts)) ".sld")
            (loop (cdr parts)
                  (string-append acc (symbol->string (car parts)) "/")))))

    (define (host-library-source-entry key)
      "Return the (path . text) source entry for host library KEY, or #f."
      (let ((relative (host-library-relative-path key)))
        (resolve-source-entry
         relative
         (list (string-append "scheme/" relative) relative))))

    (define (host-library-available? key context)
      "Report whether KEY is loadable under an active host-libraries grant."
      "Requires the grant, an internal library key, and either a compiled-in"
      "native bindings table or resolvable source, so that programs that"
      "merely define their own (consent ...) libraries are unaffected."
      (and (context-internal-libraries-allowed? context)
           (host-library-key? key)
           (or (consent-native-library-ref key)
               (host-library-source-entry key))
           #t))

    (define (register-host-source-library! key context environment)
      "Load and register runtime-internal library KEY from its source."
      (let ((entry (host-library-source-entry key)))
        (if entry
            (register-source-library! (cdr entry) context environment)
            (eval-error "host source library not found" key))))

    (define (native-callback-result value seen)
      "Convert an interpreted callback's result for native consumption."
      "Canonical number records become raw host numbers -- a custom resync"
      "strategy returns an offset the reader clamps with host arithmetic --"
      "and the interpreter's end-of-file record becomes the host end-of-file"
      "object a native input driver tests with eof-object?. Pairs and vectors"
      "are walked copy-on-write so untouched structure keeps its identity,"
      "and SEEN returns cyclic data unchanged on revisit."
      (cond
       ((consent-number? value)
        (let ((host (consent-number-value value)))
          (if (number? host) host value)))
       ((consent-eof-object? value)
        (eof-object))
       ((pair? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (head (native-callback-result (car value) next-seen))
                   (tail (native-callback-result (cdr value) next-seen)))
              (if (and (eq? head (car value)) (eq? tail (cdr value)))
                  value
                  (cons head tail)))))
       ((vector? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (length (vector-length value))
                   (converted
                    (let loop ((index 0) (acc '()) (changed #f))
                      (if (= index length)
                          (and changed (reverse acc))
                          (let* ((element (vector-ref value index))
                                 (next (native-callback-result
                                        element next-seen)))
                            (loop (+ index 1)
                                  (cons next acc)
                                  (or changed (not (eq? next element)))))))))
              (if converted (list->vector converted) value))))
       (else value)))

    (define (native-callback-shim value context)
      "Wrap interpreted callable VALUE as a host procedure applying it in"
      "CONTEXT. Arguments cross into the closure under the native result"
      "conversion (raw host numbers become canonical records, matching what"
      "interpreted code expects everywhere else) and the closure's result"
      "crosses back under the callback result conversion (canonical records"
      "become raw host numbers), so native higher-order code can consume what"
      "the closure returns."
      (let ((applier (consent-native-applier-ref)))
        (lambda arguments
          (native-callback-result
           (applier value
                    (map (lambda (argument)
                           (native-result-value argument '()))
                         arguments)
                    context)
           '()))))

    ;; Context of the native call currently crossing the import boundary.
    ;; The native binding shim maintains it dynamically so callable arguments
    ;; applied by native higher-order code run in the calling program's
    ;; context.
    (define native-call-context #f)

    (define (consent-apply-callable value arguments)
      "Apply callable VALUE to ARGUMENTS across the native import boundary."
      "Host procedures apply directly. An interpreted callable -- a closure"
      "a self-hosted program passes as a bare argument into a natively bound"
      "higher-order procedure such as the REPL engine's input driver -- runs"
      "through the native callback shim in the calling program's context,"
      "with the shim's argument and result conversions."
      #((parameters
         (value (type procedure)
          (description "Host procedure or interpreted callable to apply."))
         (arguments (type list)
          (description "List of arguments to pass to the callable.")))
        (returns . "The value produced by applying VALUE to ARGUMENTS.")
        (effects host-eval))
      (if (procedure? value)
          (apply value arguments)
          (apply (native-callback-shim value native-call-context)
                 arguments)))

    (define (native-nested-argument value context seen)
      "Convert one value nested inside a container crossing into native code."
      "Callables nested in data follow the callback convention -- a custom"
      "reader resync strategy or a policy-confirmation-function inside an"
      "options alist -- so they become host callbacks native higher-order"
      "code can apply directly. Canonical number records cross unchanged:"
      "they are the datum-position number representation the native writer"
      "and audit layers expect, and the native consumers that compare them"
      "(capability scope matching, option counts) coerce payloads through"
      "consent-number-value at the comparison site. Pairs and vectors are"
      "walked copy-on-write so untouched structure keeps its identity. SEEN"
      "guards against cyclic data, which is returned unchanged on revisit."
      (cond
       ((or (consent-procedure? value)
            (consent-primitive-procedure? value)
            (continuation? value)
            (consent-parameter? value))
        (native-callback-shim value context))
       ((pair? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (head (native-nested-argument (car value) context next-seen))
                   (tail (native-nested-argument (cdr value) context next-seen)))
              (if (and (eq? head (car value)) (eq? tail (cdr value)))
                  value
                  (cons head tail)))))
       ((vector? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (length (vector-length value))
                   (converted
                    (let loop ((index 0) (acc '()) (changed #f))
                      (if (= index length)
                          (and changed (reverse acc))
                          (let* ((element (vector-ref value index))
                                 (next (native-nested-argument
                                        element context next-seen)))
                            (loop (+ index 1)
                                  (cons next acc)
                                  (or changed (not (eq? next element)))))))))
              (if converted (list->vector converted) value))))
       (else value)))

    (define (native-argument-value value context)
      "Convert one argument crossing into native code."
      "A bare callable argument crosses unchanged: it is the runtime's own"
      "procedure record, which native predicates, accessors, and the shared"
      "apply machinery already handle (consent-procedure? on a"
      "consent-eval-source result must see the record, not a wrapper)."
      "Containers are walked so callables nested in data -- the options-alist"
      "callback convention -- become host callbacks native higher-order code"
      "can apply directly."
      (if (or (pair? value) (vector? value))
          (native-nested-argument value context '())
          value))

    (define (native-result-scalar value)
      "Wrap a host-number scalar as a canonical number record, else pass through."
      (cond
       ((not (number? value)) value)
       ((and (exact? value) (integer? value))
        (consent-make-canonical-integer value))
       ((exact? value)
        (consent-make-canonical-rational (numerator value) (denominator value)))
       ((real? value)
        (consent-make-canonical-decimal value))
       (else value)))

    (define (native-result-value value seen)
      "Convert one native RESULT for interpreted use."
      "Native unwrap accessors return raw host numbers (consent-number-value,"
      "read positions); interpreted callers expect canonical records,"
      "mirroring how char->integer wraps at the primitive boundary. A raw"
      "host procedure result (a REPL chrome lookup, for example) wraps as a"
      "native primitive through the shared binding cells so repeated lookups"
      "stay eqv? and the interpreted world can both recognize and apply it."
      "Pairs and vectors are walked copy-on-write -- canonical structure"
      "passes through untouched and keeps its identity -- and SEEN returns"
      "cyclic data unchanged on revisit."
      (cond
       ((number? value) (native-result-scalar value))
       ((procedure? value)
        (cell-value (native-binding-cell 'result value)))
       ((pair? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (head (native-result-value (car value) next-seen))
                   (tail (native-result-value (cdr value) next-seen)))
              (if (and (eq? head (car value)) (eq? tail (cdr value)))
                  value
                  (cons head tail)))))
       ((vector? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (length (vector-length value))
                   (converted
                    (let loop ((index 0) (acc '()) (changed #f))
                      (if (= index length)
                          (and changed (reverse acc))
                          (let* ((element (vector-ref value index))
                                 (next (native-result-value element next-seen)))
                            (loop (+ index 1)
                                  (cons next acc)
                                  (or changed (not (eq? next element)))))))))
              (if converted (list->vector converted) value))))
       (else value)))

    (define (native-binding-value name value)
      "Wrap native VALUE for interpreted use."
      "Host procedures become primitives whose arguments are converted under"
      "the two boundary conventions (bare callables cross as the runtime's"
      "own records, callables nested in data cross as host callbacks) and"
      "whose results are converted so raw host numbers come back canonical;"
      "every other value binds directly, because the compiled internal"
      "libraries share the runtime's value representations. The primitive"
      "name is prefixed so it can never collide with the interpreter's"
      "continuation-passing primitive dispatch names."
      (if (procedure? value)
          (make-primitive-procedure
           (string->symbol (string-append "native:" (symbol->string name)))
           (lambda (arguments context)
             (let ((previous native-call-context))
               (dynamic-wind
                (lambda () (set! native-call-context context))
                (lambda ()
                  (native-result-value
                   (apply value
                          (map (lambda (argument)
                                 (native-argument-value argument context))
                               arguments))
                   '()))
                (lambda () (set! native-call-context previous)))))
           0
           #f)
          ;; Exported data values (for example consent-version-datum) may carry
          ;; raw host numbers a native reader would consume directly; convert
          ;; them once at registration so interpreted callers see canonical
          ;; numbers.
          (native-result-value value '())))

    ;; Cache pairing each registered native value with its shared binding cell.
    (define native-binding-cells '())

    (define (native-binding-cell name value)
      "Return the shared binding cell for native VALUE, creating it on first"
      "use. Internal libraries re-export one another's bindings ((consent"
      "eval) re-exports the (consent runtime) predicates, for example), and"
      "importing two such libraries into one program is only compatible when"
      "both export records carry the same cell, so the cache is keyed by the"
      "native value itself."
      (let ((entry (assq value native-binding-cells)))
        (if entry
            (cdr entry)
            (let ((cell (make-cell (native-binding-value name value))))
              (set! native-binding-cells
                    (cons (cons value cell) native-binding-cells))
              cell))))

    (define (register-native-library! key bindings context)
      "Register internal library KEY from its compiled-in native BINDINGS table."
      (let ((value-environment (consent-make-empty-environment))
            (syntax-environment (library-make-empty-syntax-environment #f)))
        (for-each
         (lambda (binding)
           (set-environment-frame!
            value-environment
            (cons (cons (car binding)
                        (native-binding-cell (car binding) (cdr binding)))
                  (environment-frame value-environment))))
         bindings)
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
          syntax-environment))))

    (define (find-library-export name exports)
      "Return NAME's binding from EXPORTS, or #f when absent."
      (cond
       ((null? exports) #f)
       ((eq? name (library-binding-name (car exports))) (car exports))
       (else (find-library-export name (cdr exports)))))

    (define (register-subset-library! key export-names context environment)
      "Register KEY as a subset of `(scheme base)' exports."
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

    (define (filter-library-exports exports export-names key)
      "Return EXPORTS narrowed to EXPORT-NAMES for alias library KEY."
      (for-each
       (lambda (name)
         (if (not (find-library-export name exports))
             (eval-error "alias export is not available" key name)))
       export-names)
      (let loop ((rest exports) (result '()))
        (cond
         ((null? rest) (reverse result))
         ((memq (library-binding-name (car rest)) export-names)
          (loop (cdr rest) (cons (car rest) result)))
         (else (loop (cdr rest) result)))))

    (define (register-library-alias! spec context environment)
      "Register alias SPEC using its target library and optional exports."
      (let ((key (library-alias-field spec 'alias))
            (target-key (library-alias-field spec 'target))
            (export-names-entry (assq 'exports spec)))
        (if (not key)
            (eval-error "library alias has no alias name" spec))
        (if (not target-key)
            (eval-error "library alias has no target" key))
        (if (not (library-registry-ref context key))
            (let* ((target-library
                    (resolve-library target-key context environment))
                   (target-exports (library-exports target-library)))
              (library-registry-set!
               context
               key
               (make-library
                key
                key
                (if export-names-entry
                    (filter-library-exports
                     target-exports
                     (cdr export-names-entry)
                     key)
                    target-exports)
                (library-value-environment target-library)
                (library-syntax-environment target-library)))))))

    (define (library-alias-spec key aliases)
      "Return KEY's alias spec from ALIASES, or #f when KEY is not an alias."
      (cond
       ((null? aliases) #f)
       ((equal? key (library-alias-field (car aliases) 'alias))
        (car aliases))
       (else (library-alias-spec key (cdr aliases)))))

    (define (register-primitive-library! key primitive-specs context)
      "Register KEY as a library populated from primitive specs."
      (if (not (library-registry-ref context key))
          (let ((value-environment (consent-make-empty-environment))
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

    (define (char-library-specs)
      "Return primitive specs for `(scheme char)'."
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

    (define (primitive-cxr-function name)
      "Implement the `cxr-function` primitive with argument validation and"
      "Consent Scheme values."
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
                          ((library-primitive-implementation 'primitive-car)
                           (list value) context))
                         ((char=? step #\d)
                          ((library-primitive-implementation 'primitive-cdr)
                           (list value) context))
                         (else
                          (eval-error "invalid cxr name" name))))))))))

    (define (cxr-library-specs)
      "Return primitive specs for generated cxr selectors."
      (map (lambda (name)
             (list name (primitive-cxr-function name) 1 1))
           cxr-library-extra-names))

    (define (register-cxr-library! key context environment)
      "Register `(scheme cxr)' from base selectors and generated selectors."
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
                 (value-environment (consent-make-empty-environment))
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

    (define (inexact-library-specs)
      "Return primitive specs for `(scheme inexact)'."
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

    (define (policy-denied-spec name)
      "Return a primitive spec that always raises a policy-denied error."
      (list name (library-policy-denied-primitive (symbol->string name)) 0 #f))

    (define (register-r5rs-library! key context environment)
      "Register `(scheme r5rs)' with R5RS aliases for exact/inexact conversion."
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

    (define (register-standard-library! key context environment)
      "Register a supported standard library by KEY."
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
	         (append
	          (list
	           (library-primitive-spec 'command-line
	                                   'primitive-command-line
	                                   0
	                                   0))
	          (map policy-denied-spec
	               '(emergency-exit
	                 exit))
          ;; Environment reads are real, policy-gated primitives: denied unless
          ;; the context carries an active process-environment capability grant.
          (list
           (library-primitive-spec 'get-environment-variable
                                   'primitive-get-environment-variable
                                   1
                                   1)
           (library-primitive-spec 'get-environment-variables
                                   'primitive-get-environment-variables
                                   0
                                   0)))
         context))
       ((equal? key '(scheme read))
        (register-primitive-library!
         key
         (list (library-primitive-spec 'read 'primitive-read 0 1))
         context))
       ((equal? key '(scheme repl))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'interaction-environment
                                  'primitive-interaction-environment 0 0))
         context))
       ((equal? key '(scheme r5rs))
        (register-r5rs-library! key context environment))
       ((equal? key '(scheme time))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'current-jiffy
                                  'primitive-current-jiffy
                                  0
                                  0)
          (library-primitive-spec 'current-second
                                  'primitive-current-second
                                  0
                                  0)
          (library-primitive-spec 'jiffies-per-second
                                  'primitive-jiffies-per-second
                                  0
                                  0))
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

    (define (register-agent-library! key context environment)
      "Register a supported Consent Scheme interaction library by KEY."
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
       ((equal? key '(agent helper))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'agent-artifact
                                  'primitive-agent-artifact
                                  2
                                  2)
          (library-primitive-spec 'agent-helper-save!
                                  'primitive-agent-helper-save!
                                  2
                                  3)
          (library-primitive-spec 'agent-helper-load
                                  'primitive-agent-helper-load
                                  1
                                  2)
          (library-primitive-spec 'agent-helper-list
                                  'primitive-agent-helper-list
                                  1
                                  1)
          (library-primitive-spec 'agent-helper-ref
                                  'primitive-agent-helper-ref
                                  1
                                  2)
          (library-primitive-spec 'agent-helper-promote-to-skill
                                  'primitive-agent-helper-promote-to-skill
                                  1
                                  2))
         context))
       ((equal? key '(agent job))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'job-start! 'primitive-job-start! 3 3)
          (library-primitive-spec 'job-ref 'primitive-job-ref 1 1)
          (library-primitive-spec 'job-list 'primitive-job-list 0 1)
          (library-primitive-spec 'job-cancel! 'primitive-job-cancel! 1 1)
          (library-primitive-spec 'job-interrupt!
                                  'primitive-job-interrupt!
                                  2
                                  2)
          (library-primitive-spec 'job-yields 'primitive-job-yields 1 2)
          (library-primitive-spec 'job-status 'primitive-job-status 1 1))
         context))
       ((equal? key '(agent test))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent diagnostics))
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
       ((equal? key '(agent registry))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent proposal))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent runner))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent reliability))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent prompt))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent task))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent test primitive))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'agent-test-eval-source-result
                                  'primitive-agent-test-eval-source-result
                                  1
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
       ((equal? key '(agent plan))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'plan-create!
                                  'primitive-plan-create!
                                  1
                                  1)
          (library-primitive-spec 'plan-ref 'primitive-plan-ref 1 1)
          (library-primitive-spec 'plan-list 'primitive-plan-list 1 1)
          (library-primitive-spec 'plan-step-add!
                                  'primitive-plan-step-add!
                                  2
                                  2)
          (library-primitive-spec 'plan-step-status!
                                  'primitive-plan-step-status!
                                  3
                                  3)
          (library-primitive-spec 'plan-status!
                                  'primitive-plan-status!
                                  2
                                  2)
          (library-primitive-spec 'plan-yield
                                  'primitive-plan-yield
                                  1
                                  1))
         context))
       ((equal? key '(agent models))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(agent models primitive))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'primitive-model-provider-register!
                                  'primitive-model-provider-register!
                                  1
                                  1)
          (library-primitive-spec 'primitive-model-providers
                                  'primitive-model-providers
                                  0
                                  0)
          (library-primitive-spec 'primitive-model-route
                                  'primitive-model-route
                                  1
                                  2)
          (library-primitive-spec 'primitive-model-complete
                                  'primitive-model-complete
                                  2
                                  3)
          (library-primitive-spec 'primitive-model-provider-diagnostics
                                  'primitive-model-provider-diagnostics
                                  0
                                  1))
         context))
       ((equal? key '(agent context))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'current-request
                                  'primitive-current-request
                                  0
                                  0)
          (library-primitive-spec 'current-focus
                                  'primitive-current-focus
                                  0
                                  0)
          (library-primitive-spec 'current-region-context
                                  'primitive-current-region-context
                                  0
                                  0)
          (library-primitive-spec 'current-buffer-context
                                  'primitive-current-buffer-context
                                  0
                                  0)
          (library-primitive-spec 'current-project-context
                                  'primitive-current-project-context
                                  0
                                  0)
          (library-primitive-spec 'current-conversation-summary
                                  'primitive-current-conversation-summary
                                  0
                                  0)
          (library-primitive-spec 'context-yield
                                  'primitive-context-yield
                                  1
                                  1))
         context))
       ((equal? key '(agent reflect))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'consent-version
                                  'primitive-consent-version
                                  0
                                  0)
          (library-primitive-spec 'current-capabilities
                                  'primitive-current-capabilities
                                  0
                                  0)
          (library-primitive-spec 'current-policy
                                  'primitive-current-policy
                                  0
                                  0)
          (library-primitive-spec 'current-budget
                                  'primitive-current-budget
                                  0
                                  0)
          (library-primitive-spec 'budget-remaining
                                  'primitive-budget-remaining
                                  0
                                  0)
          (library-primitive-spec 'budget-exhausted?
                                  'primitive-budget-exhausted?
                                  1
                                  1)
          (library-primitive-spec 'budget-yield
                                  'primitive-budget-yield
                                  0
                                  0)
          (library-primitive-spec 'current-imports
                                  'primitive-current-imports
                                  0
                                  0)
          (library-primitive-spec 'current-session-info
                                  'primitive-current-session-info
                                  0
                                  0)
          (library-primitive-spec 'recent-yields
                                  'primitive-recent-yields
                                  0
                                  0)
          (library-primitive-spec 'recent-errors
                                  'primitive-recent-errors
                                  0
                                  0)
          (library-primitive-spec 'recent-policy-decisions
                                  'primitive-recent-policy-decisions
                                  0
                                  0)
          (library-primitive-spec 'capability-info
                                  'primitive-capability-info
                                  1
                                  1)
          (library-primitive-spec 'documentation
                                  'primitive-documentation
                                  1
                                  1)
          (library-primitive-spec 'macroexpand
                                  'primitive-macroexpand
                                  1
                                  2)
          (library-primitive-spec 'macroexpand-1
                                  'primitive-macroexpand-1
                                  1
                                  2)
          (library-primitive-spec 'macroexpand-library
                                  'primitive-macroexpand-library
                                  1
                                  2)
          (library-primitive-spec 'macro-binding-info
                                  'primitive-macro-binding-info
                                  1
                                  1)
          (library-primitive-spec 'syntax-source
                                  'primitive-syntax-source
                                  1
                                  1)
          (library-primitive-spec 'macroexpand-yield
                                  'primitive-macroexpand-yield
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
       ((equal? key '(agent session))
        (register-primitive-library!
         key
         (list
          (library-primitive-spec 'create-session
                                  'primitive-create-session
                                  0
                                  2)
          (library-primitive-spec 'switch-session
                                  'primitive-switch-session
                                  1
                                  1)
          (library-primitive-spec 'set-default-session!
                                  'primitive-switch-session
                                  1
                                  1)
          (library-primitive-spec 'current-session
                                  'primitive-current-session
                                  0
                                  0)
          (library-primitive-spec 'list-sessions
                                  'primitive-list-sessions
                                  0
                                  1)
          (library-primitive-spec 'close-session
                                  'primitive-close-session
                                  1
                                  1))
         context))
       ((equal? key '(agent transcript))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       (else
        (eval-error "unknown agent library" key))))

    (define (register-consent-library! key context environment)
      "Register a supported consent core library by KEY."
      (cond
       ((equal? key '(consent capability))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (agent-source-library-source key)
             context
             environment)))
       ((equal? key '(consent capability primitive))
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
                                  2)
          (library-primitive-spec 'handle-ref
                                  'primitive-handle-ref
                                  1
                                  1)
          (library-primitive-spec 'handle-live?
                                  'primitive-handle-live?
                                  1
                                  1)
          (library-primitive-spec 'handle-kind
                                  'primitive-handle-kind
                                  1
                                  1)
          (library-primitive-spec 'handle-revalidate
                                  'primitive-handle-revalidate
                                  1
                                  1)
          (library-primitive-spec 'handle-release!
                                  'primitive-handle-release!
                                  1
                                  1))
         context))
       (else
        (eval-error "unknown consent library" key))))

    (define (register-stdlib-library! key context environment)
      "Register a supported optional stdlib library by KEY."
      (let ((alias-spec (library-alias-spec key stdlib-library-aliases)))
        (cond
         (alias-spec
          (register-library-alias! alias-spec context environment))
         ((assoc/equal key stdlib-source-library-load-paths)
          (if (not (library-registry-ref context key))
              (register-source-library!
               (stdlib-source-library-source key)
               context
               environment)))
         ((member key stdlib-library-keys)
          (eval-error "stdlib library has no registration strategy" key))
         (else
          (eval-error "unknown stdlib library" key)))))

    (define (library-available? name context environment)
      "Report whether NAME is a known or already registered library."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to test for availability."))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry and host grant are"
             "consulted.")))
         (environment (type environment)
          (description ("Environment available for resolving the library name."))))
        (returns (type boolean)
         (description
          ("#t when NAME names a known, registered, or host-loadable"
            "library, else #f.")))
        (effects state-read error))
      (let ((key (library-name-key name)))
        (or (equal? key scheme-base-library-key)
            (member key standard-library-keys)
            (member key stdlib-library-keys)
            (member key agent-library-keys)
            (member key consent-library-keys)
            (member key empty-emacs-capability-library-keys)
            (and (library-registry-ref context key) #t)
            (host-library-available? key context))))

    (define (resolve-library name context environment)
      "Resolve NAME to a library, registering lazy standard libraries as needed."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to resolve to a registered library."))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry receives lazily"
             "registered libraries.")))
         (environment (type environment)
          (description ("Environment used when building or registering the library."))))
        (returns (type library)
         (description "The resolved library object for NAME."))
        (effects state-read state-write error))
      (let ((key (library-name-key name)))
        (cond
         ((equal? key scheme-base-library-key)
          (register-scheme-base-library! context environment))
         ((member key standard-library-keys)
          (register-standard-library! key context environment))
         ((member key stdlib-library-keys)
          (register-stdlib-library! key context environment))
         ((and (not (library-registry-ref context key))
               (host-library-available? key context))
          ;; Prefer the compiled-in native bindings (the product serving as its
          ;; own host runner at native speed); fall back to interpreting the
          ;; library's source where no native table is registered (interpreted
          ;; hosts, or libraries outside the compiled link set).
          (let ((bindings (consent-native-library-ref key)))
            (if bindings
                (register-native-library! key bindings context)
                (register-host-source-library! key context environment))))
         ((member key agent-library-keys)
          (register-agent-library! key context environment))
         ((member key consent-library-keys)
          (register-consent-library! key context environment))
         ((member key empty-emacs-capability-library-keys)
          (register-empty-emacs-capability-library! key context)))
        (or (library-registry-ref context key)
            (eval-error "unknown library" key))))

    (define (find-import-binding name bindings)
      "Return NAME's import binding from BINDINGS, or #f."
      (cond
       ((null? bindings) #f)
       ((eq? name (library-binding-name (car bindings))) (car bindings))
       (else (find-import-binding name (cdr bindings)))))

    (define (ensure-import-names-present names bindings description)
      "Reject import modifiers naming exports that are absent from BINDINGS."
      (for-each
       (lambda (name)
         (if (not (find-import-binding name bindings))
             (eval-error
              (string-append description " import name not found")
              name)))
       names))

    (define (ensure-compatible-import-bindings bindings)
      "Merge duplicate compatible imports and reject conflicting imports."
      #((parameters
         (bindings (type list)
          (description ("List of import library bindings to deduplicate and check."))))
        (returns (type list)
         (description ("A list of bindings with compatible duplicates merged.")))
        (effects error))
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

    (define (import-modifier-identifiers forms description)
      "Validate import modifier operands as symbols."
      (map (lambda (form) (expect-symbol form description)) forms))

    (define (resolve-import-set import-set context environment)
      "Resolve an import set, applying only/except/prefix/rename modifiers."
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

    (define (install-imported-binding! binding value-environment
                                       syntax-environment)
      "Install one imported value or syntax binding into the target frames."
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

    (define (install-import-set! import-set value-environment
                                 syntax-environment context)
      "Resolve IMPORT-SET and install all compatible imported bindings."
      (for-each
       (lambda (binding)
         (install-imported-binding! binding
                                    value-environment
                                    syntax-environment))
       (ensure-compatible-import-bindings
        (resolve-import-set import-set context value-environment))))

    (define (eval-import form environment context)
      "Evaluate an import declaration into the active value and syntax frames."
      #((parameters
         (form (type pair)
          (description ("Import declaration form whose import sets are installed.")))
         (environment (type environment)
          (description ("Value environment receiving the imported value bindings.")))
         (context (type eval-context)
          (description
           ("Evaluation context whose syntax environment and registry"
             "are used."))))
        (returns . ("The unspecified value after installing every import set."))
        (effects state-read state-write error))
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
        consent-unspecified))

    (define (export-specs forms)
      "Parse export clauses into internal-name/external-name pairs."
      #((parameters
         (forms (type list)
          (description ("List of export clause forms (identifiers or rename forms)."))))
        (returns (type pair)
         (description
          ("A list of internal-name/external-name pairs in declaration"
            "order.")))
        (effects error))
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

    (define (feature-requirement-satisfied? requirement context environment)
      "Report whether a cond-expand feature requirement is satisfied."
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

    (define (expand-library-cond-expand clauses context environment)
      "Select declarations from the first satisfied library cond-expand clause."
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

    (define (expand-library-declaration declaration context environment)
      "Expand library declaration wrappers such as cond-expand and includes."
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

    (define (include-filenames declaration)
      "Return string literal filenames from an include-style declaration."
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

    (define (string-prefix? prefix string)
      "Test whether TEXT begins with PREFIX."
      (let ((prefix-length (string-length prefix))
            (string-length-value (string-length string)))
        (and (<= prefix-length string-length-value)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref string index))
                        (loop (+ index 1))))))))

    (define (strip-trailing-slash path)
      "Remove a single trailing slash from PATH for policy-prefix checks."
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    (define (path-policy-allows-file? path allowed-paths)
      "Report whether PATH is exactly allowed or inside an allowed directory."
      #((parameters
         (path (type list)
          (description "File path to test against the allow-list."))
         (allowed-paths (type string)
          (description "List of allowed file or directory path strings.")))
        (returns (type boolean)
         (description
          ("#t when PATH equals or sits under an allowed path, else"
            "#f.")))
        (effects pure))
      (let loop ((rest allowed-paths))
        (and (not (null? rest))
             (let* ((allowed (strip-trailing-slash (car rest)))
                    (allowed-directory (string-append allowed "/")))
               (or (string=? path allowed)
                   (string-prefix? allowed-directory path)
                   (loop (cdr rest)))))))

    (define (include-policy-allows-file? path context)
      "Report whether PATH satisfies the current include allow-list policy."
      (path-policy-allows-file? path (context-include-paths context)))

    (define (resolve-include-file filename context operation binding)
      "Resolve FILENAME against the include directory and enforce file policy."
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

    (define (path-directory path)
      "Return PATH's directory component without the trailing slash."
      #((parameters
         (path (type string)
          (description "File path whose directory component is extracted.")))
        (returns (type string)
         (description
          ("The directory portion of PATH without a trailing slash, or"
            "the empty string.")))
        (effects pure))
      (let loop ((index (- (string-length path) 1)))
        (cond
         ((< index 0) "")
         ((char=? (string-ref path index) #\/)
          (substring path 0 index))
         (else (loop (- index 1))))))

    (define (read-file-string path)
      "Read PATH into a string using the Scheme file API."
      #((parameters
         (path (type string)
          (description "Filesystem path of the file to read.")))
        (returns (type string)
         (description ("A string holding the entire contents of the file at PATH.")))
        (effects state-read))
      (call-with-input-file
       path
       (lambda (port)
         (let loop ((chars '()))
           (let ((char (read-char port)))
             (if (eof-object? char)
                 (list->string (reverse chars))
                 (loop (cons char chars))))))))

    (define (with-include-directory context directory thunk)
      "Run THUNK with CONTEXT's include directory temporarily set."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose include directory is swapped.")))
         (directory (type string)
          (description
           ("Directory to install as the include directory during"
             "THUNK.")))
         (thunk (type procedure)
          (description
           ("Zero-argument procedure run with the temporary include"
             "directory."))))
        (returns . "The value produced by THUNK.")
        (effects state-write host-eval))
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

    (define (read-include-file-forms filename context fold-case? operation)
      "Read and parse all forms from an include file, returning forms and directory."
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
         (consent-read-all
          (if fold-case?
              (string-append "#!fold-case\n" source)
              source))
         (path-directory path))))

    (define (library-include-body-forms declaration context fold-case?)
      "Return all body forms read by an include or include-ci declaration."
      (apply append
             (map (lambda (filename)
                    (car (read-include-file-forms
                          filename
                          context
                          fold-case?
                          (if fold-case? 'include-ci 'include))))
                  (include-filenames declaration))))

    (define (expand-include-library-declarations declaration context
                                                 environment)
      "Read include-library-declarations files and expand their declarations."
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

    (define (library-export-binding spec library-key value-environment
                                    syntax-environment)
      "Resolve one export spec to a value or syntax library binding."
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

    (define (library-exports-from-specs specs library-key value-environment
                                        syntax-environment)
      "Build checked library exports from parsed export specs."
      (ensure-distinct-names (map cdr specs) "library exports")
      (ensure-compatible-import-bindings
       (map (lambda (spec)
              (library-export-binding spec
                                      library-key
                                      value-environment
                                      syntax-environment))
            specs)))

    (define (eval-library-begin forms value-environment
                                syntax-environment context)
      "Evaluate library body forms under the library syntax environment."
      (library-with-syntax-environment
       context
       syntax-environment
       (lambda ()
         (library-trampoline
          (make-sequence forms #t)
          value-environment
          context))))

    (define (eval-define-library form environment context)
      "Evaluate a define-library form and register its exported bindings."
      #((parameters
         (form (type pair)
          (description "define-library form to evaluate and register."))
         (environment (type environment)
          (description
           ("Environment used while expanding the library's"
             "declarations.")))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry receives the new"
             "library."))))
        (returns
         . ("The unspecified value after registering the defined"
            "library."))
        (effects state-read state-write host-eval error))
      (let ((parts (proper-list-elements form "define-library form")))
        (if (< (length parts) 2)
            (eval-error "define-library requires a library name"))
        (let ((name (second parts)))
          (if (not (proper-library-name? name))
              (eval-error "invalid library name" name))
          (let ((library-key (library-name-key name))
                (value-environment (consent-make-empty-environment))
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
                    consent-unspecified)
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
