;;; Portable Consent Scheme runtime values and evaluation state.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral records, lexical environment helpers,
;;; budget accounting, and datum-shape utilities shared by the portable
;;; evaluator passes.

(define-library (consent runtime)
  (export consent-default-maximum-steps
          consent-default-maximum-value-nodes
          consent-default-maximum-host-callbacks
          consent-version-components
          consent-version
          consent-set-library-search-directories!
          consent-library-search-directory-list
          consent-register-embedded-source!
          consent-embedded-source-ref
          consent-register-native-library!
          consent-native-library-ref
          consent-install-native-applier!
          consent-native-applier-ref
          consent-make-empty-environment
          consent-unspecified
          consent-unspecified?
          make-undefined
          undefined?
          undefined
          make-cell
          cell?
          cell-value
          set-cell-value!
          make-environment
          environment?
          environment-frame
          set-environment-frame!
          environment-parent
          environment-imported-names
          set-environment-imported-names!
          make-syntax-environment
          syntax-environment?
          syntax-environment-frame
          set-syntax-environment-frame!
          syntax-environment-parent
          syntax-environment-imported-names
          set-syntax-environment-imported-names!
          make-syntax-context
          syntax-context?
          syntax-context-id
          syntax-context-value-environment
          syntax-context-syntax-environment
          make-identifier
          identifier?
          identifier-name
          identifier-context
          make-formals
          formals?
          formals-required
          formals-rest
          make-documentation-metadata
          documentation-metadata?
          documentation-metadata-fields
          documentation-metadata-origins
          documentation-metadata-from-body
          documentation-body-result
          make-procedure
          consent-procedure?
          procedure-formals
          procedure-body
          procedure-environment
          procedure-documentation
          make-primitive-procedure
          consent-primitive-procedure?
          primitive-procedure-name
          primitive-procedure-function
          primitive-procedure-minimum-arity
          primitive-procedure-maximum-arity
          make-consent-parameter
          consent-parameter?
          parameter-value
          set-parameter-value!
          parameter-converter
          make-multiple-values
          multiple-values?
          multiple-values-values
          make-continuation
          continuation?
          continuation-procedure
          continuation-dynamic-winds
          continuation-exception-handlers
          continuation-current-error
          make-dynamic-wind-frame
          dynamic-wind-frame?
          dynamic-wind-frame-before
          dynamic-wind-frame-after
          make-consent-error-object
          consent-error-object?
          consent-error-object-message
          consent-error-object-irritants
          make-consent-eof-object
          consent-eof-object?
          consent-eof-object
          make-consent-port
          consent-port?
          consent-port-medium
          consent-port-input?
          consent-port-output?
          consent-port-textual?
          consent-port-binary?
          consent-port-open?
          set-consent-port-open?!
          consent-port-source
          set-consent-port-source!
          consent-port-position
          set-consent-port-position!
          consent-port-contents
          set-consent-port-contents!
          consent-port-backing-domain
          consent-port-operations
          consent-port-grant
          consent-port-limits
          consent-port-handle
          consent-port-status
          set-consent-port-status!
          consent-port-path
          consent-port-counters
          set-consent-port-counters!
          make-environment-specifier
          environment-specifier?
          environment-specifier-environment
          environment-specifier-syntax-environment
          environment-specifier-immutable?
          make-string-output-port
          string-output-port?
          string-output-port-contents
          set-string-output-port-contents!
          make-sequence
          sequence?
          sequence-forms
          sequence-allow-definitions
          make-bounce
          bounce?
          bounce-expression
          bounce-environment
          bounce-syntax-environment
          bounce-continuation
          make-eval-context
          eval-context?
          context-steps
          set-context-steps!
          context-maximum-steps
          context-maximum-value-nodes
          context-host-callbacks
          set-context-host-callbacks!
          context-maximum-host-callbacks
          context-event-count
          set-context-event-count!
          context-maximum-events
          context-maximum-event-nodes
          context-syntax-environment
          set-context-syntax-environment!
          context-libraries
          set-context-libraries!
          context-include-paths
          context-include-directory
          set-context-include-directory!
          context-file-paths
          context-internal-libraries-allowed?
          context-docstring-retention
          context-policy-actions
          context-policy-confirmation-function
          context-capability-grants
          set-context-capability-grants!
          context-active-capability-grants
          set-context-active-capability-grants!
          context-audit-events
          set-context-audit-events!
          context-current-input-port
          set-context-current-input-port!
          context-current-output-port
          set-context-current-output-port!
          context-current-error-port
          set-context-current-error-port!
          context-current-error
          set-context-current-error!
          context-session-id
          context-request-id
          context-request
          context-focus
          context-region-context
          context-buffer-context
          context-project-context
          context-conversation-summary
          context-interaction-environment
          set-context-interaction-environment!
          context-base-syntax-installed
          set-context-base-syntax-installed!
          context-next-syntax-id
          set-context-next-syntax-id!
          context-exception-handlers
          set-context-exception-handlers!
          context-dynamic-winds
          set-context-dynamic-winds!
          make-syntax-transformer
          syntax-transformer?
          syntax-transformer-ellipsis
          syntax-transformer-literals
          syntax-transformer-rules
          syntax-transformer-value-environment
          syntax-transformer-syntax-environment
          make-pattern-binding
          pattern-binding?
          pattern-binding-depth
          set-pattern-binding-depth!
          pattern-binding-captures
          set-pattern-binding-captures!
          pattern-binding-empty-prefixes
          set-pattern-binding-empty-prefixes!
          make-syntax-scope
          syntax-scope?
          syntax-scope-forms
          syntax-scope-syntax-environment
          make-library-binding
          library-binding?
          library-binding-name
          library-binding-kind
          library-binding-object
          library-binding-library-key
          make-library
          library?
          library-name
          library-key
          library-exports
          library-value-environment
          library-syntax-environment
          option-ref
          eval-error
          budget-error
          normalize-include-directory
          path-absolute?
          path-join
          path-normalize
          normalize-include-paths
          authorize-file-capability
          file-authorization-path
          audit-file-capability-result!
          authorize-code-loading
          audit-code-loading-result!
          process-capability-effect
          process-capability-policy-category
          process-capability-request
          process-capability-handle
          process-port-capability-handle
          authorize-process-capability
          authorize-process-environment-capability
          audit-process-capability-result!
          network-capability-effect
          network-capability-request
          network-capability-handle
          network-port-capability-handle
          authorize-network-capability
          audit-network-capability-result!
          authorize-clock-capability
          audit-clock-capability-result!
          new-eval-context
          record-audit-event!
          record-agent-event!
          note-step!
          note-host-callback!
          value-node-count
          check-value-budget
          values-list
          single-value
          identity-continuation
          continue
          continuation-value
          proper-list-elements
          second
          third
          fourth
          expect-symbol
          identifier-datum?
          identifier-datum-name
          identifier-key
          identifier-named?
          expect-identifier-key
          frame-cell
          environment-cell
          environment-cell-imported?
          current-environment-imported?
          environment-define!
          environment-set!
          environment-define-or-set!
          environment-ref
          environment-cell-for-identifier
          environment-ref-identifier
          environment-set-identifier!
          ensure-distinct-names
          parse-formals)
  (import (scheme base)
          (scheme char)
          (consent version)
          (consent reader)
          (consent redaction))
  (begin
    ;; Default evaluator step budget for one expansion or evaluation run.
    (define consent-default-maximum-steps 100000)
    ;; Default maximum result value graph size before budget failure.
    (define consent-default-maximum-value-nodes 100000)
    ;; Default maximum primitive callback count allowed during evaluation.
    (define consent-default-maximum-host-callbacks 10000)
    ;; Default maximum event-channel records allowed during evaluation.
    (define consent-default-maximum-events 1000)
    ;; Default maximum reachable value graph size for one event record.
    (define consent-default-maximum-event-nodes 100000)

    ;; Host-injected library/source resolution context (host/core boundary).
    ;; The portable core reads its prelude, syntax prelude, and source-backed
    ;; libraries by trying, for each logical relative path, every configured
    ;; search-directory prefix in order, then the core's built-in cwd-relative
    ;; defaults, then embedded source. A compiled or installed host injects its
    ;; CONSENT_LIBRARY_PATH, datadir, and executable-relative directories here at
    ;; startup, where host facilities exist; an in-repo/source run leaves this
    ;; empty and falls through to the cwd defaults, preserving the original
    ;; behavior. Embedded source is the zero-dependency floor, consulted only
    ;; when no on-disk copy is found.
    (define consent-library-search-directories '())

    (define (consent-set-library-search-directories! directories)
      "Replace the host-injected library search-directory prefixes, highest precedence first."
      (set! consent-library-search-directories directories)
      consent-unspecified)

    (define (consent-library-search-directory-list)
      "Return the host-injected library search-directory prefixes."
      consent-library-search-directories)

    ;; Embedded runtime source registered by a compiled host's linked-in
    ;; `(consent embedded-source)' module: an alist of logical-relative-path to
    ;; source text. Empty for interpreted/source runs.
    (define consent-embedded-source-entries '())

    (define (consent-register-embedded-source! relative-path text)
      "Register embedded source TEXT for logical RELATIVE-PATH (the zero-dependency floor)."
      (set! consent-embedded-source-entries
            (cons (cons relative-path text) consent-embedded-source-entries))
      consent-unspecified)

    (define (consent-embedded-source-ref relative-path)
      "Return registered embedded source text for RELATIVE-PATH, or #f when absent."
      (let ((entry (assoc relative-path consent-embedded-source-entries)))
        (and entry (cdr entry))))

    ;; Native-library registry: a compiled host's generated main registers, once
    ;; at startup, name->value tables for the internal libraries linked into the
    ;; executable. Under the internal-libraries grant the resolver binds those
    ;; imports to the compiled modules directly instead of re-interpreting their
    ;; source, which is what lets the product binary serve as its own host
    ;; runner at native speed. Empty for interpreted/source runs, which keep the
    ;; source-loading path.
    (define consent-native-library-entries '())

    (define (consent-register-native-library! key bindings)
      "Register native BINDINGS, an alist of (name . value), for internal library KEY."
      (set! consent-native-library-entries
            (cons (cons key bindings) consent-native-library-entries))
      consent-unspecified)

    (define (consent-native-library-ref key)
      "Return the native bindings registered for library KEY, or #f when absent."
      (let ((entry (assoc key consent-native-library-entries)))
        (and entry (cdr entry))))

    ;; Native applier hook: installed by the interpreter at load time so the
    ;; library layer can apply interpreted closures that a program passes as
    ;; callbacks into natively bound library procedures.
    (define consent-native-applier-procedure #f)

    (define (consent-install-native-applier! applier)
      "Install APPLIER, called as (APPLIER procedure arguments context), for native callbacks."
      (set! consent-native-applier-procedure applier)
      consent-unspecified)

    (define (consent-native-applier-ref)
      "Return the installed native callback applier, or #f when absent."
      consent-native-applier-procedure)

    (define (consent-version-components)
      "Return the Consent Scheme version as exact non-negative host integers."
      (cdr consent-version-datum))

    (define (consent-version)
      "Return the canonical Scheme-readable Consent Scheme version datum."
      (cons (car consent-version-datum)
            (map consent-make-canonical-integer
                 (consent-version-components))))

    ;; Record type for the singleton unspecified value returned by effect-only
    ;; forms.
    (define-record-type <consent-unspecified>
      (make-unspecified)
      consent-unspecified?
      (tag unspecified-tag))

    ;; Singleton value representing Scheme results whose value is unspecified.
    (define consent-unspecified (make-unspecified))

    ;; Record type for internal uninitialized bindings used during recursive
    ;; setup.
    (define-record-type <undefined>
      (make-undefined)
      undefined?
      (tag undefined-tag))

    ;; Singleton sentinel for internal bindings that must not be read yet.
    (define undefined (make-undefined))

    ;; Record type for mutable lexical storage shared by closures and
    ;; environments.
    (define-record-type <cell>
      (make-cell value)
      cell?
      (value cell-value set-cell-value!))

    ;; Value environments are internal mutable frames; imported names mark the
    ;; current frame bindings that Scheme source cannot redefine or mutate.
    (define-record-type <environment>
      ;; FRAME maps lexical keys to mutable cells.  IMPORTED-NAMES marks
      ;; current-frame imports that Scheme code may not redefine or mutate.
      (make-environment frame parent imported-names)
      environment?
      (frame environment-frame set-environment-frame!)
      (parent environment-parent)
      (imported-names environment-imported-names
                      set-environment-imported-names!))

    ;; Record type for syntax frames, parent links, and immutable imported
    ;; syntax names.
    (define-record-type <syntax-environment>
      (make-syntax-environment frame parent imported-names)
      syntax-environment?
      (frame syntax-environment-frame set-syntax-environment-frame!)
      (parent syntax-environment-parent)
      (imported-names syntax-environment-imported-names
                      set-syntax-environment-imported-names!))

    ;; Syntax contexts carry macro-introduced identifier provenance across
    ;; expansion without exposing host objects to Scheme values.
    (define-record-type <syntax-context>
      ;; Macro templates attach this context to introduced identifiers so free
      ;; identifiers resolve in the transformer's definition environments.
      (make-syntax-context id value-environment syntax-environment)
      syntax-context?
      (id syntax-context-id)
      (value-environment syntax-context-value-environment)
      (syntax-environment syntax-context-syntax-environment))

    ;; Record type for an identifier name plus optional macro syntax context.
    (define-record-type <identifier>
      (make-identifier name context)
      identifier?
      (name identifier-name)
      (context identifier-context))

    ;; Record type for parsed lambda formals split into required and rest
    ;; names.
    (define-record-type <formals>
      (make-formals required rest)
      formals?
      (required formals-required)
      (rest formals-rest))

    ;; Documentation metadata is extracted from ordinary non-final body
    ;; literals and later rendered through `(agent reflect)'.
    (define-record-type <documentation-metadata>
      (make-documentation-metadata fields origins)
      documentation-metadata?
      (fields documentation-metadata-fields)
      (origins documentation-metadata-origins))

    ;; Record type for compound Scheme procedures and their closure
    ;; environment.
    (define-record-type <procedure>
      (make-procedure formals body environment documentation)
      consent-procedure?
      (formals procedure-formals)
      (body procedure-body)
      (environment procedure-environment)
      (documentation procedure-documentation))

    ;; Primitive procedures are the kernel boundary: each call is budgeted as a
    ;; host callback even when the primitive implements pure R7RS behavior.
    (define-record-type <primitive-procedure>
      (make-primitive-procedure name function minimum-arity maximum-arity)
      consent-primitive-procedure?
      (name primitive-procedure-name)
      (function primitive-procedure-function)
      (minimum-arity primitive-procedure-minimum-arity)
      (maximum-arity primitive-procedure-maximum-arity))

    ;; Record type for parameter procedure state and optional conversion
    ;; function.
    (define-record-type <consent-parameter>
      (make-consent-parameter value converter)
      consent-parameter?
      (value parameter-value set-parameter-value!)
      (converter parameter-converter))

    ;; Record type for packaged multiple return values crossing evaluator
    ;; boundaries.
    (define-record-type <multiple-values>
      (make-multiple-values values)
      multiple-values?
      (values multiple-values-values))

    ;; Continuations snapshot the user procedure plus dynamic context so
    ;; repeated invocation can re-run dynamic-wind and handler transitions.
    (define-record-type <continuation>
      (make-continuation procedure dynamic-winds exception-handlers
                         current-error)
      continuation?
      (procedure continuation-procedure)
      (dynamic-winds continuation-dynamic-winds)
      (exception-handlers continuation-exception-handlers)
      (current-error continuation-current-error))

    ;; Record type for before/after thunks active in dynamic-wind stacks.
    (define-record-type <dynamic-wind-frame>
      (make-dynamic-wind-frame before after)
      dynamic-wind-frame?
      (before dynamic-wind-frame-before)
      (after dynamic-wind-frame-after))

    ;; Record type for Scheme error objects with messages and irritants.
    (define-record-type <consent-error-object>
      (make-consent-error-object message irritants)
      consent-error-object?
      (message consent-error-object-message)
      (irritants consent-error-object-irritants))

    ;; Record type for the singleton EOF object used by Consent Scheme ports.
    (define-record-type <consent-eof-object>
      (make-consent-eof-object)
      consent-eof-object?)

    ;; Singleton EOF object returned by Consent Scheme input primitives.
    (define consent-eof-object (make-consent-eof-object))

    ;; Portable ports keep backing storage as Scheme data; host-file access is
    ;; still explicit policy surface even though this record is host-neutral.
    (define-record-type <consent-port>
      ;; MEDIUM separates string, bytevector, host-file, and virtual ports.
      ;; SOURCE/POSITION back input ports; CONTENTS backs output ports.
      (make-consent-port medium input? output? textual? binary?
                              open? source position contents
                              backing-domain operations grant limits handle
                              status path counters)
      consent-port?
      (medium consent-port-medium)
      (input? consent-port-input?)
      (output? consent-port-output?)
      (textual? consent-port-textual?)
      (binary? consent-port-binary?)
      (open? consent-port-open? set-consent-port-open?!)
      (source consent-port-source set-consent-port-source!)
      (position consent-port-position set-consent-port-position!)
      (contents consent-port-contents
                set-consent-port-contents!)
      (backing-domain consent-port-backing-domain)
      (operations consent-port-operations)
      (grant consent-port-grant)
      (limits consent-port-limits)
      (handle consent-port-handle)
      (status consent-port-status set-consent-port-status!)
      (path consent-port-path)
      (counters consent-port-counters
                set-consent-port-counters!))

    ;; Record type for eval environment specifiers and their mutability policy.
    (define-record-type <environment-specifier>
      (make-environment-specifier environment syntax-environment immutable?)
      environment-specifier?
      (environment environment-specifier-environment)
      (syntax-environment environment-specifier-syntax-environment)
      (immutable? environment-specifier-immutable?))

    ;; Record type for accumulating string output port contents.
    (define-record-type <string-output-port>
      (make-string-output-port contents)
      string-output-port?
      (contents string-output-port-contents
                set-string-output-port-contents!))

    ;; Record type for evaluation bodies and whether definitions are currently
    ;; allowed.
    (define-record-type <sequence>
      (make-sequence forms allow-definitions)
      sequence?
      (forms sequence-forms)
      (allow-definitions sequence-allow-definitions))

    ;; Record type for trampoline states that preserve tail calls.
    (define-record-type <bounce>
      (make-bounce expression environment syntax-environment continuation)
      bounce?
      (expression bounce-expression)
      (environment bounce-environment)
      (syntax-environment bounce-syntax-environment)
      (continuation bounce-continuation))

    ;; Evaluation context is the per-run owner for budgets, library state,
    ;; include policy, syntax allocation, and dynamic control stacks.
    (define-record-type <eval-context>
      ;; A context owns mutable run state: budgets, active syntax bindings,
      ;; lazy library registrations, include policy, and syntax-id allocation.
      (make-eval-context steps maximum-steps
                         maximum-value-nodes host-callbacks
                         maximum-host-callbacks syntax-environment libraries
                         include-paths include-directory file-paths
                         docstring-retention
                         policy-actions policy-confirmation-function
                         capability-grants active-capability-grants
                         event-count maximum-events maximum-event-nodes
                         audit-events
                         current-input-port current-output-port
                         current-error-port
                         current-error
                         session-id request-id request focus
                         region-context buffer-context project-context
                         conversation-summary
                         interaction-environment
                         base-syntax-installed next-syntax-id
                         exception-handlers dynamic-winds
                         internal-libraries-allowed)
      eval-context?
      (steps context-steps set-context-steps!)
      (maximum-steps context-maximum-steps)
      (maximum-value-nodes context-maximum-value-nodes)
      (host-callbacks context-host-callbacks set-context-host-callbacks!)
      (maximum-host-callbacks context-maximum-host-callbacks)
      (event-count context-event-count set-context-event-count!)
      (maximum-events context-maximum-events)
      (maximum-event-nodes context-maximum-event-nodes)
      (syntax-environment context-syntax-environment
                          set-context-syntax-environment!)
      (libraries context-libraries set-context-libraries!)
      (include-paths context-include-paths)
      (include-directory context-include-directory
                         set-context-include-directory!)
      (file-paths context-file-paths)
      (docstring-retention context-docstring-retention)
      (policy-actions context-policy-actions)
      (policy-confirmation-function context-policy-confirmation-function)
      (capability-grants context-capability-grants
                         set-context-capability-grants!)
      (active-capability-grants context-active-capability-grants
                                set-context-active-capability-grants!)
      (audit-events context-audit-events set-context-audit-events!)
      (current-input-port context-current-input-port
                          set-context-current-input-port!)
      (current-output-port context-current-output-port
                           set-context-current-output-port!)
      (current-error-port context-current-error-port
                          set-context-current-error-port!)
      (current-error context-current-error set-context-current-error!)
      (session-id context-session-id)
      (request-id context-request-id)
      (request context-request)
      (focus context-focus)
      (region-context context-region-context)
      (buffer-context context-buffer-context)
      (project-context context-project-context)
      (conversation-summary context-conversation-summary)
      (interaction-environment context-interaction-environment
                               set-context-interaction-environment!)
      (base-syntax-installed context-base-syntax-installed
                             set-context-base-syntax-installed!)
      (next-syntax-id context-next-syntax-id set-context-next-syntax-id!)
      (exception-handlers context-exception-handlers
                          set-context-exception-handlers!)
      (dynamic-winds context-dynamic-winds set-context-dynamic-winds!)
      ;; When true, imported programs may load the runtime's own internal
      ;; libraries ((consent ...)/(cli ...)) from source -- the host capability
      ;; grant that lets the compiled runtime act as a full Scheme host runner.
      (internal-libraries-allowed context-internal-libraries-allowed?))

    ;; Syntax transformers remember their definition environments; expansion
    ;; relies on this for syntax-rules hygiene instead of host macro state.
    (define-record-type <syntax-transformer>
      (make-syntax-transformer ellipsis literals rules
                               value-environment syntax-environment)
      syntax-transformer?
      (ellipsis syntax-transformer-ellipsis)
      (literals syntax-transformer-literals)
      (rules syntax-transformer-rules)
      (value-environment syntax-transformer-value-environment)
      (syntax-environment syntax-transformer-syntax-environment))

    ;; Record type for syntax-rules pattern captures and ellipsis paths.
    (define-record-type <pattern-binding>
      ;; Captures are keyed by nested ellipsis paths such as `(0 2)'.  Empty
      ;; prefixes record zero-length repetitions needed by template checks.
      (make-pattern-binding depth captures empty-prefixes)
      pattern-binding?
      (depth pattern-binding-depth set-pattern-binding-depth!)
      (captures pattern-binding-captures set-pattern-binding-captures!)
      (empty-prefixes pattern-binding-empty-prefixes
                      set-pattern-binding-empty-prefixes!))

    ;; Record type for expanded forms that must run under a specific syntax
    ;; environment.
    (define-record-type <syntax-scope>
      (make-syntax-scope forms syntax-environment)
      syntax-scope?
      (forms syntax-scope-forms)
      (syntax-environment syntax-scope-syntax-environment))

    ;; Record type for imported/exported library value and syntax bindings.
    (define-record-type <library-binding>
      (make-library-binding name kind object library-key)
      library-binding?
      (name library-binding-name)
      (kind library-binding-kind)
      (object library-binding-object)
      (library-key library-binding-library-key))

    ;; Library records are immutable snapshots of exported value and syntax
    ;; environments after declarations have been evaluated.
    (define-record-type <library>
      (make-library name key exports value-environment syntax-environment)
      library?
      (name library-name)
      (key library-key)
      (exports library-exports)
      (value-environment library-value-environment)
      (syntax-environment library-syntax-environment))

    (define (option-ref options key default)
      "Return the option value for KEY or DEFAULT when KEY is absent."
      (let ((cell (assq key options)))
        (if cell (cdr cell) default)))

    (define (eval-error message . irritants)
      "Raise an evaluator error with the Consent Scheme diagnostic prefix."
      (apply error
             (string-append "consent eval error: " message)
             irritants))

    (define (budget-error message . irritants)
      "Raise an evaluator budget error with the Consent Scheme diagnostic prefix."
      (apply error
             (string-append "consent budget error: " message)
             irritants))

    (define (normalize-docstring-retention value)
      "Return the normalized docstring retention mode for VALUE."
      (cond
       ((eq? value #t) 'full)
       ((eq? value #f) 'none)
       ((memq value '(full simple none)) value)
       (else
        (eval-error
         "docstring-retention must be full, simple, none, or #f"
         value))))

    (define (normalize-include-directory directory)
      "Normalize include-directory options to a stable prefix form."
      (cond
       ((or (string=? directory "")
            (string=? directory "."))
        "")
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        directory)
       (else
        (string-append directory "/"))))

    (define (path-absolute? path)
      "Report whether PATH is absolute for include/load path resolution."
      (and (> (string-length path) 0)
           (char=? (string-ref path 0) #\/)))

    (define (path-join directory path)
      "Join DIRECTORY and PATH unless PATH is already absolute."
      (cond
       ((or (string=? directory "") (path-absolute? path))
        path)
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        (string-append directory path))
       (else
        (string-append directory "/" path))))

    (define (path-split path)
      "Split PATH on slash characters, preserving empty components for absolute path detection while letting normalization discard redundant separators."
      (let ((length (string-length path)))
        (let loop ((index 0) (start 0) (parts '()))
          (cond
           ((= index length)
            (reverse (cons (substring path start index) parts)))
           ((char=? (string-ref path index) #\/)
            (loop (+ index 1)
                  (+ index 1)
                  (cons (substring path start index) parts)))
           (else
            (loop (+ index 1) start parts))))))

    (define (path-join-parts parts)
      "Join path PARTS with slash separators."
      (cond
       ((null? parts) "")
       ((null? (cdr parts)) (car parts))
       (else
        (string-append (car parts) "/" (path-join-parts (cdr parts))))))

    (define (path-normalize path)
      "Resolve . and .. path components without consulting the host filesystem."
      (let ((absolute? (path-absolute? path)))
        (let loop ((parts (path-split path)) (stack '()))
          (cond
           ((null? parts)
            (let ((joined (path-join-parts (reverse stack))))
              (cond
               ((and absolute? (string=? joined "")) "/")
               (absolute? (string-append "/" joined))
               (else joined))))
           ((or (string=? (car parts) "")
                (string=? (car parts) "."))
            (loop (cdr parts) stack))
           ((string=? (car parts) "..")
            (cond
             ((and (pair? stack) (not (string=? (car stack) "..")))
              (loop (cdr parts) (cdr stack)))
             (absolute?
              (loop (cdr parts) stack))
             (else
              (loop (cdr parts) (cons ".." stack)))))
           (else
            (loop (cdr parts) (cons (car parts) stack)))))))

    (define (capability-field datum field)
      "Return FIELD from DATUM, or #f when it is absent."
      (let ((entry (and (pair? datum) (assq field (cdr datum)))))
        (if entry entry #f)))

    (define (capability-field-value datum field)
      "Return the first value for FIELD from DATUM, or #f."
      (let ((entry (capability-field datum field)))
        (if (and entry (pair? (cdr entry))) (cadr entry) #f)))

    (define (capability-field-values datum field)
      "Return every value for FIELD from DATUM."
      (let ((entry (capability-field datum field)))
        (if entry (cdr entry) '())))

    (define (capability-flatten-values values)
      "Flatten a Scheme field that may store its values as one nested list."
      (if (and (pair? values)
               (null? (cdr values))
               (list? (car values))
               (not (null? (car values))))
          (car values)
          values))

    (define (capability-scope-clause grant name)
      "Return the scope clause named NAME from GRANT."
      (let ((scope (capability-field-values grant 'scope)))
        (let loop ((rest scope))
          (cond
           ((null? rest) #f)
           ((and (pair? (car rest)) (eq? (caar rest) name)) (car rest))
           (else (loop (cdr rest)))))))

    (define (capability-scope-value grant name)
      "Return the first scope value named NAME from GRANT."
      (let ((clause (capability-scope-clause grant name)))
        (if (and clause (pair? (cdr clause))) (cadr clause) #f)))

    (define (capability-scope-values grant name)
      "Return flattened scope values named NAME from GRANT."
      (let ((clause (capability-scope-clause grant name)))
        (if clause (capability-flatten-values (cdr clause)) '())))

    (define (file-capability-grant? grant)
      "Report whether GRANT is an active file-domain grant."
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-field-value grant 'domain) 'file)))

    (define (capability-grant-active? grant)
      "Report whether GRANT currently has active status."
      (let ((status (capability-field-value grant 'status)))
        (or (not status) (eq? status 'active))))

    (define (file-capability-operation? grant operation)
      "Report whether GRANT authorizes OPERATION."
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (eq? (car operations) operation)
                 (loop (cdr operations))))))

    (define (file-capability-grants context)
      "Return file-domain grants from CONTEXT."
      (let loop ((grants (context-capability-grants context)) (kept '()))
        (cond
         ((null? grants) (reverse kept))
         ((file-capability-grant? (car grants))
          (loop (cdr grants) (cons (car grants) kept)))
         (else
          (loop (cdr grants) kept)))))

    (define (legacy-file-capability-grants paths operation)
      "Return a synthetic file grant for legacy allow-list PATHS."
      (if (null? paths)
          '()
          (list
           (list 'capability-grant
                 (list 'id 'legacy-file-path-policy)
                 (list 'domain 'file)
                 (list 'operations operation)
                 (list 'scope
                       (list 'file-root "")
                       (cons 'paths paths)
                       (list 'remote 'denied)
                       (list 'symlinks 'portable-unresolved))
                 (list 'expires 'after-eval)
                 (list 'status 'active)))))

    (define (string-prefix? prefix text)
      "Test whether TEXT begins with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref text index))
                        (loop (+ index 1))))))))

    (define (strip-trailing-slash path)
      "Remove a single trailing slash from PATH for prefix checks."
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    (define (string-contains? text needle)
      "Report whether TEXT contains NEEDLE."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    (define (remote-file-path? filename)
      "Report whether FILENAME names a non-local resource outside file grants."
      (string-contains? filename "://"))

    (define (file-capability-effect operation)
      "Return the effect class for a file capability operation."
      (if (memq operation '(write create delete))
          'host-file-mutation
          'read-only-observation))

    (define (path-contained? path root)
      "Report whether PATH is equal to or nested inside ROOT."
      (let* ((normalized-path (path-normalize path))
             (normalized-root (strip-trailing-slash (path-normalize root)))
             (root-directory (string-append normalized-root "/")))
        (or (string=? normalized-path normalized-root)
            (string-prefix? root-directory normalized-path))))

    (define (file-capability-roots grant context)
      "Return normalized allowed roots described by GRANT."
      (let* ((project-root (capability-scope-value grant 'project-root))
             (file-root (capability-scope-value grant 'file-root))
             (base-root
              (or project-root file-root (context-include-directory context)))
             (paths (let ((values (capability-scope-values grant 'paths)))
                      (if (null? values) '(".") values))))
        (map (lambda (path)
               (path-normalize
                (if (path-absolute? path)
                    path
                    (path-join base-root path))))
             paths)))

    (define (file-capability-match grants path operation context)
      "Return a matching grant for PATH and OPERATION, or a denial reason."
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         ((not (file-capability-operation? (car rest) operation))
          (loop (cdr rest) denied))
         ((not (capability-grant-active? (car rest)))
          (loop (cdr rest)
                (list 'denied (car rest) "expired file capability grant")))
         (else
          (let root-loop ((roots (file-capability-roots
                                  (car rest)
                                  context)))
            (cond
             ((null? roots)
              (loop (cdr rest)
                    (list 'denied
                          (car rest)
                          "path is outside approved file grant root")))
             ((path-contained? path (car roots))
              (list 'approved (car rest) (car roots)))
             (else
              (root-loop (cdr roots)))))))))

    (define (file-capability-request filename path operation binding)
      "Return a portable file capability request datum."
      (list 'capability-request
            (list 'library
                  (cond
                   ((memq operation '(include include-ci library-source))
                    '(scheme base))
                   ((eq? operation 'load) '(scheme load))
                   (else '(scheme file))))
            (list 'binding binding)
            (list 'domain 'file)
            (list 'operation operation)
            (list 'resource
                  (list 'path filename)
                  (list 'normalized-path path))
            (list 'effect (file-capability-effect operation))))

    (define (file-capability-handle path grant)
      "Return a portable Scheme-readable file handle datum."
      (list 'handle
            (list 'id (string-append "file:" path))
            (list 'kind 'file)
            (list 'domain 'file)
            (list 'path path)
            (list 'grant (capability-field-value grant 'id))
            (list 'status 'live)))

    (define (deny-file-capability! context request operation grant reason)
      "Record DENIAL for REQUEST and raise a portable evaluator error."
      (let* ((grant-id (if grant
                           (capability-field-value grant 'id)
                           'none))
             (decision
              (list 'capability-decision
                    (list 'request request)
                    (list 'status 'denied)
                    (list 'grant grant-id)
                    (list 'reason reason))))
        (record-audit-event!
         context
         'capability-decision
         (list (list 'request request)
               (list 'decision decision)
               (list 'status 'denied)
               (list 'grant grant-id)
               (list 'reason reason)))
        (record-audit-event!
         context
         'capability-audit
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'file)
               (list 'operation operation)
               (list 'result (list 'error reason))))
        (eval-error (string-append "file capability denied: " reason))))

    (define (authorize-file-capability
             filename context operation binding legacy-paths)
      "Authorize FILENAME for file OPERATION and return authorization data."
      (let* ((path (path-normalize
                    (path-join (context-include-directory context)
                               filename)))
             (request
              (file-capability-request filename path operation binding))
             (grants
              (append (file-capability-grants context)
                      (legacy-file-capability-grants
                       legacy-paths
                       operation))))
        (record-audit-event!
         context
         'capability-request
         (list (list 'request request)
               (list 'domain 'file)
               (list 'operation operation)
               (list 'path filename)
               (list 'normalized-path path)))
        (if (remote-file-path? filename)
            (deny-file-capability!
             context
             request
             operation
             #f
             "remote file paths require a non-file capability domain"))
        (if (null? grants)
            (begin
              (record-audit-event!
               context
               'policy-decision
               (list (list 'category 'standard-host-effect)
                     (list 'operation binding)
                     (list 'decision 'denied)
                     (list 'filename filename)
                     (list 'path path)))
              (deny-file-capability!
               context
               request
               operation
               #f
               (string-append binding
                              " requires policy-gated host file access"))))
        (let ((match (file-capability-match grants path operation context)))
          (if (or (not match) (eq? (car match) 'denied))
              (deny-file-capability!
               context
               request
               operation
               (and match (cadr match))
               (if match
                   (third match)
                   "no active file grant covers path")))
          (let* ((grant (cadr match))
                 (root (third match))
                 (decision
                  (list 'capability-decision
                        (list 'request request)
                        (list 'status 'approved)
                        (list 'grant (capability-field-value grant 'id))
                        (list 'attenuation
                              (list 'root root)
                              (list 'path path))
                        (list 'reason
                              "path is inside approved file grant root"))))
            (record-audit-event!
             context
             'policy-decision
             (list (list 'category 'standard-host-effect)
                   (list 'operation binding)
                   (list 'decision 'allowed)
                   (list 'filename filename)
                   (list 'path path)))
            (record-audit-event!
             context
             'capability-decision
             (list (list 'request request)
                   (list 'decision decision)
                   (list 'status 'approved)
                   (list 'grant (capability-field-value grant 'id))
                   (list 'path path)
                   (list 'approved-root root)))
            (record-audit-event!
             context
             'capability-handle
             (list (list 'handle (file-capability-handle path grant))
                   (list 'domain 'file)
                   (list 'kind 'file)
                   (list 'path path)
                   (list 'grant (capability-field-value grant 'id))
                   (list 'status 'live)))
            (list (list 'path path)
                  (list 'request request)
                  (list 'decision decision)
                  (list 'operation operation)
                  (list 'grant grant)
                  (list 'handle (file-capability-handle path grant)))))))

    (define (file-authorization-path authorization)
      "Return the authorized normalized host path from AUTHORIZATION."
      (cadr (assq 'path authorization)))

    (define (audit-file-capability-result!
             context authorization result error?)
      "Record the result of an authorized file capability operation."
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (assq 'request authorization)))
             (list 'decision (cadr (assq 'decision authorization)))
             (list 'domain 'file)
             (list 'operation (cadr (assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error result)
                       (list 'ok result))))))

    (define (code-loading-request authorization binding)
      "Return a portable code-loading request datum."
      (let ((path (file-authorization-path authorization)))
        (list 'capability-request
              (list 'library '(scheme load))
              (list 'binding binding)
              (list 'domain 'code-loading)
              (list 'operation 'load)
              (list 'resource
                    (list 'path path)
                    (list 'file-request
                          (cadr (assq 'request authorization))))
              (list 'effect 'environment-mutation))))

    (define (authorize-code-loading authorization context binding)
      "Authorize evaluation of source forms read by a file capability request."
      (let* ((path (file-authorization-path authorization))
             (request (code-loading-request authorization binding))
             (decision
              (list 'capability-decision
                    (list 'request request)
                    (list 'status 'approved)
                    (list 'domain 'code-loading)
                    (list 'reason
                          "load target is authorized under current evaluation context"))))
        (record-audit-event!
         context
         'capability-request
         (list (list 'request request)
               (list 'domain 'code-loading)
               (list 'operation 'load)
               (list 'binding binding)
               (list 'path path)))
        (record-audit-event!
         context
         'policy-decision
         (list (list 'category 'standard-host-effect)
               (list 'operation binding)
               (list 'decision 'allowed)
               (list 'domain 'code-loading)
               (list 'path path)))
        (record-audit-event!
         context
         'capability-decision
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'code-loading)
               (list 'operation 'load)
               (list 'status 'approved)
               (list 'path path)))
        (list (list 'path path)
              (list 'request request)
              (list 'decision decision)
              (list 'operation 'load))))

    (define (audit-code-loading-result!
             context authorization result error?)
      "Record the result of a code-loading capability operation."
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (assq 'request authorization)))
             (list 'decision (cadr (assq 'decision authorization)))
             (list 'domain 'code-loading)
             (list 'operation 'load)
             (list 'result
                   (if error?
                       (list 'error result)
                       (list 'ok result))))))

    (define (clock-capability-grant? grant)
      "Report whether GRANT is a clock-domain capability grant."
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-field-value grant 'domain) 'clock)))

    (define (clock-capability-operation? grant operation)
      "Report whether GRANT authorizes clock OPERATION."
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (eq? (car operations) operation)
                 (eq? (car operations) 'read)
                 (loop (cdr operations))))))

    (define (clock-capability-grants context)
      "Return clock-domain grants from CONTEXT."
      (let loop ((grants (context-capability-grants context)) (kept '()))
        (cond
         ((null? grants) (reverse kept))
         ((clock-capability-grant? (car grants))
          (loop (cdr grants) (cons (car grants) kept)))
         (else
          (loop (cdr grants) kept)))))

    (define (clock-capability-match grants operation)
      "Return a clock grant match for OPERATION, or the strongest denial."
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         ((not (clock-capability-operation? (car rest) operation))
          (loop (cdr rest) denied))
         ((eq? (capability-field-value (car rest) 'status) 'revoked)
          (loop (cdr rest)
                (list 'denied
                      (car rest)
                      "revoked clock capability grant")))
         ((not (capability-grant-active? (car rest)))
          (loop (cdr rest)
                (list 'denied
                      (car rest)
                      "expired clock capability grant")))
         (else
          (list 'approved (car rest))))))

    (define (clock-capability-request binding operation)
      "Return a portable clock capability request datum."
      (list 'capability-request
            (list 'library '(scheme time))
            (list 'binding binding)
            (list 'domain 'clock)
            (list 'operation operation)
            (list 'resource (list 'clock 'system))
            (list 'effect 'read-only-observation)))

    (define (clock-capability-decision request status grant reason)
      "Return a clock capability decision datum."
      (list 'capability-decision
            (list 'request request)
            (list 'status status)
            (list 'domain 'clock)
            (list 'grant (if grant (capability-field-value grant 'id) 'none))
            (list 'reason reason)))

    (define (deny-clock-capability!
             context request operation grant reason)
      "Record DENIAL for clock REQUEST and raise a portable evaluator error."
      (let ((decision
             (clock-capability-decision request 'denied grant reason)))
        (record-audit-event!
         context
         'capability-decision
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'clock)
               (list 'operation operation)
               (list 'status 'denied)
               (list 'grant
                     (if grant (capability-field-value grant 'id) 'none))
               (list 'reason reason)))
        (record-audit-event!
         context
         'capability-audit
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'clock)
               (list 'operation operation)
               (list 'result (list 'error reason))))
        (eval-error (string-append "clock capability denied: " reason))))

    (define (clock-policy-action context)
      "Return CONTEXT's standard host-effect policy action for clock reads."
      (let ((entry (assq 'standard-host-effect
                         (context-policy-actions context))))
        (if entry (cdr entry) 'allow)))

    (define (authorize-clock-policy!
             context request binding operation grant)
      "Require policy approval after a clock grant covers the operation."
      (let ((grant-id (capability-field-value grant 'id)))
        (if (eq? (clock-policy-action context) 'allow)
            (record-audit-event!
             context
             'policy-decision
             (list (list 'category 'standard-host-effect)
                   (list 'operation binding)
                   (list 'decision 'allowed)
                   (list 'domain 'clock)
                   (list 'grant grant-id)))
            (begin
              (record-audit-event!
               context
               'policy-decision
               (list (list 'category 'standard-host-effect)
                     (list 'operation binding)
                     (list 'decision 'denied)
                     (list 'domain 'clock)
                     (list 'grant grant-id)))
              (deny-clock-capability!
               context
               request
               operation
               grant
               "clock request denied by policy")))))

    (define (process-environment-capability-grant? grant)
      "Report whether GRANT is an active process-environment-domain grant."
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-field-value grant 'domain) 'process-environment)
           (capability-grant-active? grant)))

    (define (process-environment-granted? context)
      "Report whether CONTEXT carries an active process-environment grant."
      (let loop ((grants (context-capability-grants context)))
        (and (pair? grants)
             (or (process-environment-capability-grant? (car grants))
                 (loop (cdr grants))))))

    (define (authorize-process-environment-capability binding context)
      "Authorize a policy-gated `(scheme process-context)' environment read.
Host environment access is denied unless CONTEXT carries an active
process-environment capability grant, so it stays opt-in and revocable while
remaining available to a caller that deliberately grants it. Records the
capability decision for the audit trail and raises on denial."
      (record-audit-event!
       context
       'capability-request
       (list (list 'domain 'process-environment)
             (list 'operation binding)))
      (if (process-environment-granted? context)
          (begin
            (record-audit-event!
             context
             'policy-decision
             (list (list 'category 'standard-host-effect)
                   (list 'operation binding)
                   (list 'decision 'allowed)
                   (list 'domain 'process-environment)))
            #t)
          (begin
            (record-audit-event!
             context
             'policy-decision
             (list (list 'category 'standard-host-effect)
                   (list 'operation binding)
                   (list 'decision 'denied)
                   (list 'domain 'process-environment)))
            (eval-error
             (string-append binding " requires policy-gated host access")))))

    (define (authorize-clock-capability binding context)
      "Authorize a policy-gated `(scheme time)` clock read."
      (let* ((operation binding)
             (request (clock-capability-request binding operation))
             (grants (clock-capability-grants context)))
        (record-audit-event!
         context
         'capability-request
         (list (list 'request request)
               (list 'domain 'clock)
               (list 'operation operation)
               (list 'binding binding)))
        (if (null? grants)
            (begin
              (record-audit-event!
               context
               'policy-decision
               (list (list 'category 'standard-host-effect)
                     (list 'operation binding)
                     (list 'decision 'denied)
                     (list 'domain 'clock)))
              (deny-clock-capability!
               context
               request
               operation
               #f
               "no active clock grant covers request")))
        (let ((match (clock-capability-match grants operation)))
          (if (or (not match) (eq? (car match) 'denied))
              (deny-clock-capability!
               context
               request
               operation
               (and match (second match))
               (if match
                   (third match)
                   "no active clock grant covers request")))
          (let* ((grant (second match))
                 (decision
                  (clock-capability-decision
                   request
                   'approved
                   grant
                   "clock read is covered by active grant")))
            (authorize-clock-policy!
             context
             request
             binding
             operation
             grant)
            (record-audit-event!
             context
             'capability-decision
             (list (list 'request request)
                   (list 'decision decision)
                   (list 'domain 'clock)
                   (list 'operation operation)
                   (list 'status 'approved)
                   (list 'grant (capability-field-value grant 'id))
                   (list 'reason
                         "clock read is covered by active grant")))
            (list (list 'request request)
                  (list 'decision decision)
                  (list 'operation operation)
                  (list 'grant grant))))))

    (define (audit-clock-capability-result!
             context authorization result error?)
      "Record the result of an authorized clock capability operation."
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (assq 'request authorization)))
             (list 'decision (cadr (assq 'decision authorization)))
             (list 'domain 'clock)
             (list 'operation (cadr (assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error result)
                       (list 'ok result))))))

    (define (process-name-string value)
      "Return VALUE as a string name when it names a host process resource."
      (cond
       ((symbol? value) (symbol->string value))
       ((string? value) value)
       (else #f)))

    (define (process-member-equal? value values)
      "Return #t when VALUE is in VALUES using equal?."
      (cond
       ((null? values) #f)
       ((equal? value (car values)) #t)
       (else (process-member-equal? value (cdr values)))))

    (define (process-resource-fields resource)
      "Return RESOURCE's field alist, accepting either a plain field list or a `(resource ...)` datum."
      (if (and (pair? resource) (eq? (car resource) 'resource))
          (cdr resource)
          resource))

    (define (process-resource-field-values resource field)
      "Return all values for RESOURCE FIELD."
      (let ((entry (assq field (process-resource-fields resource))))
        (if entry (cdr entry) '())))

    (define (process-resource-value resource field)
      "Return RESOURCE FIELD's first value, or #f."
      (let ((values (process-resource-field-values resource field)))
        (if (pair? values) (car values) #f)))

    (define (process-resource-values resource field)
      "Return RESOURCE FIELD's values, flattening single nested list fields."
      (capability-flatten-values
       (process-resource-field-values resource field)))

    (define (process-capability-effect operation)
      "Return the effect class for a process capability operation."
      (if (memq operation '(spawn input interrupt terminate))
          'process-control
          'read-only-observation))

    (define (process-capability-policy-category operation)
      "Return the policy category for a process capability operation."
      (if (eq? (process-capability-effect operation) 'process-control)
          'command-process
          'emacs-read-only))

    (define (process-capability-grant? grant)
      "Report whether GRANT is a process-domain grant."
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-field-value grant 'domain) 'process)))

    (define (process-capability-operation? grant operation)
      "Report whether GRANT authorizes process OPERATION."
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (eq? (car operations) operation)
                 (loop (cdr operations))))))

    (define (process-capability-grants context)
      "Return process-domain grants from CONTEXT."
      (let loop ((grants (context-capability-grants context)) (kept '()))
        (cond
         ((null? grants) (reverse kept))
         ((process-capability-grant? (car grants))
          (loop (cdr grants) (cons (car grants) kept)))
         (else
          (loop (cdr grants) kept)))))

    (define (process-environment-entry-name entry)
      "Return process ENVIRONMENT entry's variable name."
      (process-name-string
       (if (pair? entry) (car entry) entry)))

    (define (process-environment-names environment)
      "Return process ENVIRONMENT variable names."
      (let loop ((rest environment) (names '()))
        (if (null? rest)
            (reverse names)
            (loop (cdr rest)
                  (cons (process-environment-entry-name (car rest))
                        names)))))

    (define (process-subset? left right)
      "Return #t when every LEFT value is a member of RIGHT."
      (cond
       ((null? left) #t)
       ((process-member-equal? (car left) right)
        (process-subset? (cdr left) right))
       (else #f)))

    (define (process-scope-command grant)
      "Return GRANT's process command scope as a string, or #f."
      (let ((command (capability-scope-value grant 'command)))
        (and command (process-name-string command))))

    (define (process-scope-cwd grant)
      "Return GRANT's process working directory scope, or #f."
      (or (capability-scope-value grant 'working-directory)
          (capability-scope-value grant 'cwd)))

    (define (process-scope-environment grant)
      "Return GRANT's process environment variable scope, or #f."
      (let ((values (capability-scope-values grant 'environment)))
        (and (pair? values)
             (process-environment-names values))))

    (define (process-scope-handle grant)
      "Return GRANT's process handle scope, or #f."
      (or (capability-scope-value grant 'handle)
          (capability-scope-value grant 'process)))

    (define (process-scope-denial grant resource)
      "Return a process scope denial reason, or #f when RESOURCE is in scope."
      (let ((scope-command (process-scope-command grant))
            (scope-arguments (capability-scope-values grant 'arguments))
            (scope-cwd (process-scope-cwd grant))
            (scope-environment (process-scope-environment grant))
            (scope-handle (process-scope-handle grant))
            (command (process-resource-value resource 'command))
            (arguments (process-resource-values resource 'arguments))
            (cwd (process-resource-value resource 'cwd))
            (environment (process-resource-values resource 'environment))
            (handle (process-resource-value resource 'handle)))
        (cond
         ((and scope-command
               command
               (not (equal? scope-command command)))
          "command is outside approved process grant scope")
         ((and (pair? scope-arguments)
               (pair? arguments)
               (not (equal? scope-arguments arguments)))
          "arguments are outside approved process grant scope")
         ((and scope-cwd cwd (not (equal? scope-cwd cwd)))
          "working directory is outside approved process grant scope")
         ((and (pair? environment) (not scope-environment))
          "environment is outside approved process grant scope")
         ((and (pair? environment)
               (not (process-subset?
                     (process-environment-names environment)
                     scope-environment)))
          "environment is outside approved process grant scope")
         ((and scope-handle handle (not (equal? scope-handle handle)))
          "handle is outside approved process grant scope")
         (else #f))))

    (define (process-capability-match grants operation resource)
      "Return a matching process grant for RESOURCE and OPERATION, or a denial tuple."
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         ((not (process-capability-operation? (car rest) operation))
          (loop (cdr rest) denied))
         ((eq? (capability-field-value (car rest) 'status) 'revoked)
          (loop (cdr rest)
                (list 'denied
                      (car rest)
                      "revoked process capability grant")))
         ((not (capability-grant-active? (car rest)))
          (loop (cdr rest)
                (list 'denied
                      (car rest)
                      "expired process capability grant")))
         (else
          (let ((reason (process-scope-denial (car rest) resource)))
            (if reason
                (loop (cdr rest) (list 'denied (car rest) reason))
                (list 'approved (car rest))))))))

    (define (process-command-allowed? command allow-list)
      "Return #t when COMMAND is in ALLOW-LIST."
      (let loop ((rest allow-list))
        (and (pair? rest)
             (or (equal? command (process-name-string (car rest)))
                 (loop (cdr rest))))))

    (define (process-capability-request library binding operation resource)
      "Return a host-neutral process capability request datum."
      (list 'capability-request
            (list 'library library)
            (list 'binding binding)
            (list 'domain 'process)
            (list 'operation operation)
            (cons 'resource
                  (redact (process-resource-fields resource) 'local-only))
            (list 'effect (process-capability-effect operation))))

    (define (process-capability-decision request status grant reason)
      "Return a process capability decision datum."
      (list 'capability-decision
            (list 'request request)
            (list 'status status)
            (list 'domain 'process)
            (list 'grant (if grant (capability-field-value grant 'id) 'none))
            (list 'reason reason)))

    (define (deny-process-capability!
             context request operation grant reason)
      "Record DENIAL for process REQUEST and raise a portable evaluator error."
      (let ((decision
             (process-capability-decision request 'denied grant reason)))
        (record-audit-event!
         context
         'capability-decision
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'process)
               (list 'operation operation)
               (list 'status 'denied)
               (list 'grant
                     (if grant (capability-field-value grant 'id) 'none))
               (list 'reason reason)))
        (record-audit-event!
         context
         'capability-audit
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'process)
               (list 'operation operation)
               (list 'result (list 'error reason))))
        (eval-error
         (string-append "process capability denied: " reason))))

    (define (process-policy-action context category)
      "Return CONTEXT's configured policy action for CATEGORY."
      (let ((entry (assq category (context-policy-actions context))))
        (cond
         (entry (cdr entry))
         ((eq? category 'emacs-read-only) 'allow)
         (else 'deny))))

    (define (authorize-process-policy!
             context request binding operation resource grant)
      "Require host policy approval for a process capability request."
      (let* ((category (process-capability-policy-category operation))
             (action (process-policy-action context category))
             (grant-id (capability-field-value grant 'id)))
        (if (eq? action 'allow)
            (record-audit-event!
             context
             'policy-decision
             (list (list 'category category)
                   (list 'operation binding)
                   (list 'decision 'allowed)
                   (list 'domain 'process)
                   (list 'resource
                         (redact (process-resource-fields resource)
                                 'local-only))
                   (list 'grant grant-id)))
            (begin
              (record-audit-event!
               context
               'policy-decision
               (list (list 'category category)
                     (list 'operation binding)
                     (list 'decision 'denied)
                     (list 'domain 'process)
                     (list 'resource
                           (redact (process-resource-fields resource)
                                   'local-only))
                     (list 'grant grant-id)))
              (deny-process-capability!
               context
               request
               operation
               grant
               "process request denied by policy")))))

    (define (authorize-process-capability
             library binding context operation resource command-allow-list)
      "Authorize a host adapter process request against the shared process capability vocabulary.  This does not start or observe a real process; adapters call it before touching host process APIs."
      (let* ((request
              (process-capability-request
               library
               binding
               operation
               resource))
             (command (process-resource-value resource 'command))
             (grants (process-capability-grants context)))
        (record-audit-event!
         context
         'capability-request
         (list (list 'request request)
               (list 'domain 'process)
               (list 'operation operation)
               (list 'binding binding)
               (list 'command (redact command 'local-only))
               (list 'arguments
                     (redact
                      (process-resource-values resource 'arguments)
                      'local-only))
               (list 'environment
                     (redact
                      (process-resource-values resource 'environment)
                      'local-only))
               (list 'cwd
                     (redact (process-resource-value resource 'cwd)
                             'local-only))))
        (if (and (eq? operation 'spawn)
                 command
                 (not (process-command-allowed?
                       command
                       command-allow-list)))
            (deny-process-capability!
             context
             request
             operation
             #f
             "command is not in process allow-list"))
        (if (null? grants)
            (deny-process-capability!
             context
             request
             operation
             #f
             "no active process grant covers request"))
        (let ((match
               (process-capability-match grants operation resource)))
          (if (or (not match) (eq? (car match) 'denied))
              (deny-process-capability!
               context
               request
               operation
               (and match (second match))
               (if match
                   (third match)
                   "no active process grant covers request")))
          (let* ((grant (second match))
                 (decision
                  (process-capability-decision
                   request
                   'approved
                   grant
                   "process request is covered by active grant")))
            (authorize-process-policy!
             context
             request
             binding
             operation
             resource
             grant)
            (record-audit-event!
             context
             'capability-decision
             (list (list 'request request)
                   (list 'decision decision)
                   (list 'domain 'process)
                   (list 'operation operation)
                   (list 'status 'approved)
                   (list 'grant (capability-field-value grant 'id))
                   (list 'reason
                         "process request is covered by active grant")))
            (list (list 'request request)
                  (list 'decision decision)
                  (list 'operation operation)
                  (list 'grant grant))))))

    (define (process-capability-handle id resource grant status)
      "Return a Scheme-readable process job handle datum."
      (list 'handle
            (list 'id id)
            (list 'kind 'process-job)
            (list 'domain 'process)
            (list 'command
                  (redact (process-resource-value resource 'command)
                          'local-only))
            (list 'arguments
                  (redact
                   (process-resource-values resource 'arguments)
                   'local-only))
            (list 'grant grant)
            (list 'status status)))

    (define (process-port-capability-handle
             id kind process-handle operations grant limits status)
      "Return a Scheme-readable process-backed port capability datum."
      (list 'port-capability
            (list 'id id)
            (list 'kind kind)
            (list 'backing 'process)
            (cons 'operations operations)
            (list 'grant grant)
            (cons 'limits limits)
            (list 'path process-handle)
            (list 'status status)))

    (define (audit-process-capability-result!
             context authorization result error?)
      "Record the result of an authorized process capability operation."
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (assq 'request authorization)))
             (list 'decision (cadr (assq 'decision authorization)))
             (list 'domain 'process)
             (list 'operation (cadr (assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error (redact result 'local-only))
                       (list 'ok (redact result 'local-only)))))))

    (define (network-resource-fields resource)
      "Return RESOURCE's field alist, accepting either a plain field list or a `(resource ...)` datum."
      (if (and (pair? resource) (eq? (car resource) 'resource))
          (cdr resource)
          resource))

    (define (network-resource-field-values resource field)
      "Return all values for RESOURCE FIELD."
      (let ((entry (assq field (network-resource-fields resource))))
        (if entry (cdr entry) '())))

    (define (network-resource-value resource field)
      "Return RESOURCE FIELD's first value, or #f."
      (let ((values (network-resource-field-values resource field)))
        (if (pair? values) (car values) #f)))

    (define (network-resource-values resource field)
      "Return RESOURCE FIELD's values, flattening single nested list fields."
      (capability-flatten-values
       (network-resource-field-values resource field)))

    (define (network-public-datum datum)
      "Convert host-owned network metadata to Consent Scheme datums before publishing it through result or audit records."
      (cond
       ((consent-number? datum) datum)
       ((and (number? datum) (integer? datum))
        (consent-make-canonical-integer datum))
       ((number? datum)
        (consent-make-canonical-decimal datum))
       ((pair? datum)
        (cons (network-public-datum (car datum))
              (network-public-datum (cdr datum))))
       ((vector? datum)
        (list->vector
         (map network-public-datum (vector->list datum))))
       (else datum)))

    (define (network-redacted-public-datum datum)
      "Redact network metadata, then make it safe for external rendering."
      (network-public-datum (redact datum 'local-only)))

    (define (network-member-equal? value values)
      "Return #t when VALUE is in VALUES using equal?."
      (cond
       ((null? values) #f)
       ((equal? value (car values)) #t)
       (else (network-member-equal? value (cdr values)))))

    (define (network-subset? left right)
      "Return #t when every LEFT value is a member of RIGHT."
      (cond
       ((null? left) #t)
       ((or (null? right) (network-member-equal? 'all right)) #t)
       ((network-member-equal? (car left) right)
        (network-subset? (cdr left) right))
       (else #f)))

    (define (network-value-covered? value allowed)
      "Return #t when VALUE is covered by ALLOWED values."
      (or (null? allowed)
          (network-member-equal? 'all allowed)
          (network-member-equal? value allowed)))

    (define (network-capability-effect operation)
      "Return the effect class for a network capability operation."
      (if (eq? operation 'stream)
          'network-stream
          'network-egress))

    (define (network-capability-grant? grant)
      "Report whether GRANT is a network-domain grant."
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-field-value grant 'domain) 'network)))

    (define (network-capability-operation? grant operation)
      "Report whether GRANT authorizes network OPERATION."
      (let loop ((operations
                  (capability-flatten-values
                   (capability-field-values grant 'operations))))
        (and (pair? operations)
             (or (eq? (car operations) operation)
                 (eq? (car operations) 'all)
                 (loop (cdr operations))))))

    (define (network-capability-grants context)
      "Return network-domain grants from CONTEXT."
      (let loop ((grants (context-capability-grants context)) (kept '()))
        (cond
         ((null? grants) (reverse kept))
         ((network-capability-grant? (car grants))
          (loop (cdr grants) (cons (car grants) kept)))
         (else
          (loop (cdr grants) kept)))))

    (define (capability-number-payload value)
      "Return VALUE's host number payload for capability scope comparisons.
Canonical number records arrive in grant and resource datum positions when
requests cross the native import boundary; comparing payloads makes record
and host forms match the same way on every posture."
      (if (consent-number? value) (consent-number-value value) value))

    (define (network-scope-denial grant resource)
      "Return a network scope denial reason, or #f when RESOURCE is in scope."
      (let ((schemes (capability-scope-values grant 'schemes))
            (hosts (capability-scope-values grant 'hosts))
            (ports (map capability-number-payload
                        (capability-scope-values grant 'ports)))
            (methods (capability-scope-values grant 'methods))
            (header-classes (capability-scope-values grant 'header-classes))
            (payload-classes (capability-scope-values grant 'payload-classes))
            (max-response-bytes
             (capability-number-payload
              (capability-scope-value grant 'max-response-bytes)))
            (max-redirects
             (capability-number-payload
              (capability-scope-value grant 'max-redirects)))
            (max-timeout-ms
             (capability-number-payload
              (capability-scope-value grant 'max-timeout-ms)))
            (max-stream-lifetime-ms
             (capability-number-payload
              (capability-scope-value grant 'stream-lifetime-ms)))
            (scheme (network-resource-value resource 'scheme))
            (host (network-resource-value resource 'host))
            (port (capability-number-payload
                   (network-resource-value resource 'port)))
            (method (network-resource-value resource 'method))
            (resource-header-classes
             (network-resource-values resource 'header-classes))
            (payload-class
             (network-resource-value resource 'payload-class))
            (response-size
             (capability-number-payload
              (network-resource-value resource 'response-size)))
            (redirects
             (or (capability-number-payload
                  (network-resource-value resource 'redirects))
                 0))
            (timeout-ms
             (capability-number-payload
              (network-resource-value resource 'timeout-ms)))
            (stream-lifetime-ms
             (capability-number-payload
              (network-resource-value resource 'stream-lifetime-ms))))
        (cond
         ((not (network-value-covered? scheme schemes))
          "scheme is outside approved network grant scope")
         ((not (network-value-covered? host hosts))
          "host is outside approved network grant scope")
         ((not (network-value-covered? port ports))
          "port is outside approved network grant scope")
         ((not (network-value-covered? method methods))
          "method is outside approved network grant scope")
         ((not (network-subset? resource-header-classes header-classes))
          "header class is outside approved network grant scope")
         ((not (network-value-covered? payload-class payload-classes))
          "payload class is outside approved network grant scope")
         ((and max-response-bytes
               response-size
               (> response-size max-response-bytes))
          "response size is outside approved network grant scope")
         ((and max-redirects (> redirects max-redirects))
          "redirect count is outside approved network grant scope")
         ((and max-timeout-ms timeout-ms (> timeout-ms max-timeout-ms))
          "timeout is outside approved network grant scope")
         ((and max-stream-lifetime-ms
               stream-lifetime-ms
               (> stream-lifetime-ms max-stream-lifetime-ms))
          "stream lifetime is outside approved network grant scope")
         (else #f))))

    (define (network-capability-match grants operation resource)
      "Return a matching network grant for RESOURCE and OPERATION, or a denial tuple."
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         ((not (network-capability-operation? (car rest) operation))
          (loop (cdr rest) denied))
         ((eq? (capability-field-value (car rest) 'status) 'revoked)
          (loop (cdr rest)
                (list 'denied
                      (car rest)
                      "revoked network capability grant")))
         ((not (capability-grant-active? (car rest)))
          (loop (cdr rest)
                (list 'denied
                      (car rest)
                      "expired network capability grant")))
         (else
          (let ((reason (network-scope-denial (car rest) resource)))
            (if reason
                (loop (cdr rest) (list 'denied (car rest) reason))
                (list 'approved (car rest))))))))

    (define (network-capability-request library binding operation resource)
      "Return a host-neutral network capability request datum."
      (list 'capability-request
            (list 'library library)
            (list 'binding binding)
            (list 'domain 'network)
            (list 'operation operation)
            (cons 'resource
                  (network-redacted-public-datum
                   (network-resource-fields resource)))
            (list 'effect (network-capability-effect operation))))

    (define (network-capability-decision request status grant reason)
      "Return a network capability decision datum."
      (list 'capability-decision
            (list 'request request)
            (list 'status status)
            (list 'domain 'network)
            (list 'grant (if grant (capability-field-value grant 'id) 'none))
            (list 'reason reason)))

    (define (deny-network-capability!
             context request operation grant reason)
      "Record DENIAL for network REQUEST and raise a portable evaluator error."
      (let ((decision
             (network-capability-decision request 'denied grant reason)))
        (record-audit-event!
         context
         'capability-decision
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'network)
               (list 'operation operation)
               (list 'status 'denied)
               (list 'grant
                     (if grant (capability-field-value grant 'id) 'none))
               (list 'reason reason)))
        (record-audit-event!
         context
         'capability-audit
         (list (list 'request request)
               (list 'decision decision)
               (list 'domain 'network)
               (list 'operation operation)
               (list 'result (list 'error reason))))
        (eval-error
         (string-append "network capability denied: " reason))))

    (define (network-policy-action context)
      "Return CONTEXT's configured network policy action."
      (let ((entry (assq 'network-access (context-policy-actions context))))
        (if entry (cdr entry) 'deny)))

    (define (authorize-network-policy!
             context request binding operation resource grant)
      "Require host policy approval for a network capability request."
      (let ((action (network-policy-action context))
            (grant-id (capability-field-value grant 'id)))
        (if (eq? action 'allow)
            (record-audit-event!
             context
             'policy-decision
             (list (list 'category 'network-access)
                   (list 'operation binding)
                   (list 'decision 'allowed)
                   (list 'domain 'network)
                   (list 'resource
                         (network-redacted-public-datum
                          (network-resource-fields resource)))
                   (list 'grant grant-id)))
            (begin
              (record-audit-event!
               context
               'policy-decision
               (list (list 'category 'network-access)
                     (list 'operation binding)
                     (list 'decision 'denied)
                     (list 'domain 'network)
                     (list 'resource
                           (network-redacted-public-datum
                            (network-resource-fields resource)))
                     (list 'grant grant-id)))
              (deny-network-capability!
               context
               request
               operation
               grant
               "network request denied by policy")))))

    (define (authorize-network-capability
             library binding context operation resource)
      "Authorize a host adapter network request against the shared network capability vocabulary. This does not perform transport."
      (let* ((request
              (network-capability-request
               library
               binding
               operation
               resource))
             (grants (network-capability-grants context)))
        (record-audit-event!
         context
         'capability-request
         (list (list 'request request)
               (list 'domain 'network)
               (list 'operation operation)
               (list 'binding binding)
               (list 'scheme
                     (network-public-datum
                      (network-resource-value resource 'scheme)))
               (list 'host
                     (network-public-datum
                      (network-resource-value resource 'host)))
               (list 'port
                     (network-public-datum
                      (network-resource-value resource 'port)))
               (list 'method
                     (network-public-datum
                      (network-resource-value resource 'method)))
               (list 'header-classes
                     (network-public-datum
                      (network-resource-values resource 'header-classes)))
               (list 'payload-class
                     (network-public-datum
                      (network-resource-value resource 'payload-class)))
               (list 'payload
                     (network-redacted-public-datum
                      (network-resource-value resource 'payload)))
               (list 'response-size
                     (network-public-datum
                      (network-resource-value resource 'response-size)))
               (list 'redirects
                     (network-public-datum
                      (or (network-resource-value resource 'redirects)
                          0)))))
        (if (null? grants)
            (deny-network-capability!
             context
             request
             operation
             #f
             "no active network grant covers request"))
        (let ((match
               (network-capability-match grants operation resource)))
          (if (or (not match) (eq? (car match) 'denied))
              (deny-network-capability!
               context
               request
               operation
               (and match (second match))
               (if match
                   (third match)
                   "no active network grant covers request")))
          (let* ((grant (second match))
                 (decision
                  (network-capability-decision
                   request
                   'approved
                   grant
                   "network request is covered by active grant")))
            (authorize-network-policy!
             context
             request
             binding
             operation
             resource
             grant)
            (record-audit-event!
             context
             'capability-decision
             (list (list 'request request)
                   (list 'decision decision)
                   (list 'domain 'network)
                   (list 'operation operation)
                   (list 'status 'approved)
                   (list 'grant (capability-field-value grant 'id))
                   (list 'reason
                         "network request is covered by active grant")))
            (list (list 'request request)
                  (list 'decision decision)
                  (list 'operation operation)
                  (list 'grant grant))))))

    (define (network-capability-handle id request url grant status)
      "Return a Scheme-readable network stream handle datum."
      (list 'handle
            (list 'id id)
            (list 'kind 'network-stream)
            (list 'domain 'network)
            (list 'request request)
            (list 'url url)
            (list 'grant grant)
            (list 'status status)))

    (define (network-port-capability-handle
             id kind stream-handle operations grant limits status)
      "Return a Scheme-readable network-backed port capability datum."
      (list 'port-capability
            (list 'id id)
            (list 'kind kind)
            (list 'backing 'network)
            (cons 'operations operations)
            (list 'grant grant)
            (cons 'limits limits)
            (list 'path stream-handle)
            (list 'status status)))

    (define (audit-network-capability-result!
             context authorization result error?)
      "Record the result of an authorized network capability operation."
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (assq 'request authorization)))
             (list 'decision (cadr (assq 'decision authorization)))
             (list 'domain 'network)
             (list 'operation (cadr (assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error
                             (network-redacted-public-datum result))
                       (list 'ok
                             (network-redacted-public-datum result)))))))

    (define (normalize-include-paths paths directory)
      "Resolve relative include paths against the active include directory."
      (map (lambda (path)
             (path-normalize (path-join directory path)))
           paths))

    (define (option-count options key default)
      "Return numeric option KEY as a host count.
A canonical number record is unwrapped: a caller whose options alist crossed
the compiled host-runner boundary carries canonical numbers where a native
call site would have written host literals."
      (let ((value (option-ref options key default)))
        (if (consent-number? value)
            (consent-number-value value)
            value)))

    (define (new-eval-context options)
      "Create a fresh evaluation context from user option overrides."
      (let ((include-directory
             (normalize-include-directory
              (option-ref options 'include-directory "."))))
      (make-eval-context
       0
       (if (assq 'max-steps options)
           (option-count options 'max-steps consent-default-maximum-steps)
           (option-count options
                         'max-non-tail-steps
                         consent-default-maximum-steps))
       (option-count options
                     'max-value-nodes
                     consent-default-maximum-value-nodes)
       0
       (option-count options
                     'max-host-callbacks
                     consent-default-maximum-host-callbacks)
       (make-syntax-environment '() #f '())
       '()
       (normalize-include-paths
        (option-ref options 'include-paths '())
        include-directory)
       include-directory
       (normalize-include-paths
        (option-ref options 'file-paths '())
        include-directory)
       (normalize-docstring-retention
        (option-ref options 'docstring-retention 'full))
       (option-ref options 'policy-actions '())
       (option-ref options 'policy-confirmation-function #f)
       (option-ref options 'capability-grants '())
       '()
       0
       (option-count options
                     'max-events
                     consent-default-maximum-events)
       (option-count options
                     'max-event-nodes
                     consent-default-maximum-event-nodes)
       '()
       #f
       #f
       #f
       #f
       (option-ref options 'session-id #f)
       (option-ref options 'request-id #f)
       (option-ref options 'request #f)
       (option-ref options 'focus #f)
       (option-ref options 'region-context #f)
       (option-ref options 'buffer-context #f)
       (option-ref options 'project-context #f)
       (option-ref options 'conversation-summary #f)
       #f
       #f
       0
       '()
       '()
       (option-ref options 'internal-libraries-allowed #f))))

    (define (record-audit-event! context event fields)
      "Record a Scheme-readable audit EVENT with FIELDS in CONTEXT."
      (let ((entry (cons 'audit-entry
                         (cons (list 'event event) fields))))
        (set-context-audit-events!
         context
         (cons entry (context-audit-events context)))
        entry))

    (define (record-agent-event! context event)
      "Record an ordered event-channel EVENT after enforcing event budgets."
      (let ((node-count (value-node-count event '())))
        (if (> node-count (context-maximum-event-nodes context))
            (budget-error "event node budget exceeded"
                          node-count
                          (context-maximum-event-nodes context))))
      (if (>= (context-event-count context)
              (context-maximum-events context))
          (budget-error "event count budget exceeded"
                        (+ (context-event-count context) 1)
                        (context-maximum-events context)))
      (set-context-event-count!
       context
       (+ (context-event-count context) 1))
      (set-context-audit-events!
       context
       (cons event (context-audit-events context)))
      event)

    (define (note-step! context)
      "Charge one evaluator step against the active step budget."
      (set-context-steps! context (+ (context-steps context) 1))
      (if (> (context-steps context) (context-maximum-steps context))
          (budget-error "evaluation step budget exceeded"
                        (context-maximum-steps context))))

    (define (note-host-callback! context primitive)
      "Charge one primitive callback against the host-callback budget."
      (set-context-host-callbacks!
       context
       (+ (context-host-callbacks context) 1))
      (if (> (context-host-callbacks context)
             (context-maximum-host-callbacks context))
          (budget-error "host callback budget exceeded"
                        (primitive-procedure-name primitive))))

    (define (value-node-count value seen . maybe-tolerant)
      "Count the reachable nodes in VALUE while tolerating cycles.
An optional truthy MAYBE-TOLERANT argument counts unrecognized host values as
opaque leaves instead of raising: under the internal-libraries grant, natively
bound library procedures legitimately return their own host record types, so
the canonical-value tripwire is relaxed only for that trusted posture."
      (let ((tolerant (and (pair? maybe-tolerant) (car maybe-tolerant))))
        (cond
         ((or (boolean? value)
              (null? value)
              (symbol? value)
              (identifier? value)
              (char? value)
              ;; Raw host numbers reach here legitimately: public accessors such
              ;; as `consent-number-value' unwrap canonical numbers to host
              ;; integers/reals, and such a value can be an evaluation result.
              (number? value)
              (consent-number? value)
              (consent-unspecified? value)
              (consent-procedure? value)
              (consent-primitive-procedure? value)
              (consent-parameter? value)
              (continuation? value)
              (consent-error-object? value)
              (consent-eof-object? value)
              (consent-port? value)
              (environment-specifier? value)
              (string-output-port? value)
              (consent-record-type? value))
          1)
         ((consent-record? value)
          (if (memq value seen)
              0
              (let ((fields (consent-record-fields value)))
                (let loop ((index 0) (count 1))
                  (if (= index (vector-length fields))
                      count
                      (loop (+ index 1)
                            (+ count
                               (value-node-count
                                (vector-ref fields index)
                                (cons value seen)
                                tolerant))))))))
         ((multiple-values? value)
          (+ 1
             (let loop ((rest (multiple-values-values value)) (count 0))
               (if (null? rest)
                   count
                   (loop (cdr rest)
                         (+ count
                            (value-node-count (car rest) seen tolerant)))))))
         ((string? value)
          (+ 1 (string-length value)))
         ((bytevector? value)
          (+ 1 (bytevector-length value)))
         ((pair? value)
          (if (memq value seen)
              0
              (+ 1
                 (value-node-count (car value) (cons value seen) tolerant)
                 (value-node-count (cdr value) (cons value seen) tolerant))))
         ((vector? value)
          (if (memq value seen)
              0
              (let loop ((index 0) (count 1))
                (if (= index (vector-length value))
                    count
                    (loop (+ index 1)
                          (+ count
                             (value-node-count
                              (vector-ref value index)
                              (cons value seen)
                              tolerant)))))))
         (tolerant 1)
         (else
          (eval-error "unsupported Scheme value" value)))))

    (define (check-value-budget value context)
      "Reject VALUE when its reachable node count exceeds the result budget."
      (let ((count (value-node-count
                    value
                    '()
                    (and context
                         (context-internal-libraries-allowed? context)))))
        (if (> count (context-maximum-value-nodes context))
            (budget-error "value node budget exceeded"
                          count
                          (context-maximum-value-nodes context))))
      value)

    (define (values-list value)
      "Unpack a single or multiple-value result into a list."
      (if (multiple-values? value)
          (multiple-values-values value)
          (list value)))

    (define (single-value value description)
      "Require VALUE to contain exactly one Scheme value."
      (let ((values (values-list value)))
        (if (not (= (length values) 1))
            (eval-error
             (string-append description " expected one value")
             (length values)))
        (car values)))

    (define (identity-continuation value)
      "Default continuation that returns its input value unchanged."
      value)

    (define (continue continuation value)
      "Invoke a continuation procedure with VALUE."
      (continuation value))

    (define (continuation-value arguments)
      "Package continuation arguments as one value or multiple values."
      (if (= (length arguments) 1)
          (car arguments)
          (make-multiple-values arguments)))

    (define (proper-list-elements datum description)
      "Return DATUM as a proper list or raise an evaluator error."
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else
          (eval-error
           (string-append description " must be a proper list"))))))

    (define (proper-list? datum)
      "Report whether DATUM is a proper Scheme list."
      (let loop ((cursor datum))
        (cond
         ((null? cursor) #t)
         ((pair? cursor) (loop (cdr cursor)))
         (else #f))))

    ;; Documentation metadata fields whose list values append in source order.
    (define documentation-list-field-names '(examples see-also))

    (define (documentation-field fields name)
      "Return FIELDS entry named NAME, or #f."
      (assq name fields))

    (define (documentation-add-origin origins origin)
      "Return ORIGINS with ORIGIN appended once in source order."
      (if (memq origin origins)
          origins
          (append origins (list origin))))

    (define (documentation-set-field fields name value)
      "Return FIELDS with NAME set to VALUE, preserving field order."
      (if (documentation-field fields name)
          (map (lambda (field)
                 (if (eq? (car field) name)
                     (cons name value)
                     field))
               fields)
          (append fields (list (cons name value)))))

    (define (documentation-add-field fields name value)
      "Return FIELDS with NAME/VALUE appended."
      (append fields (list (cons name value))))

    (define (documentation-formals->datum formals)
      (define (dotted required rest)
        (if (null? required)
            rest
            (cons (car required) (dotted (cdr required) rest))))
      "Return FORMALS as a Scheme-readable arguments datum."
      (let ((required (formals-required formals))
            (rest (formals-rest formals)))
        (cond
         ((not rest) required)
         ((null? required) rest)
         (else (dotted required rest)))))

    (define (documentation-metadata-from-formals formals)
      "Return generated documentation metadata for lambda FORMALS."
      (let ((parsed (if (formals? formals) formals (parse-formals formals))))
        (make-documentation-metadata
         (list (cons 'arguments (documentation-formals->datum parsed)))
         '())))

    (define (documentation-metadata-fields-present? metadata)
      "Report whether METADATA contains at least one field."
      (and metadata (not (null? (documentation-metadata-fields metadata)))))

    (define (documentation-join-strings strings)
      "Join adjacent simple string docstrings with the documented separator."
      (cond
       ((null? strings) "")
       ((null? (cdr strings)) (car strings))
       (else
        (string-append (car strings)
                       "\n"
                       (documentation-join-strings (cdr strings))))))

    (define (documentation-parameter-names parameters)
      "Return `(ok . names)' for valid parameter alists, otherwise #f."
      (if (not (proper-list? parameters))
          #f
          (let loop ((rest parameters) (names '()))
            (cond
             ((null? rest) (cons 'ok (reverse names)))
             ((not (pair? (car rest))) #f)
             ((not (symbol? (car (car rest)))) #f)
             ((memq (car (car rest)) names) #f)
             (else
              (loop (cdr rest) (cons (car (car rest)) names)))))))

    (define (documentation-argument-names arguments)
      "Return `(ok . names)' for valid argument datums, otherwise #f."
      (cond
       ((symbol? arguments) (cons 'ok (list arguments)))
       (else
        (let loop ((cursor arguments) (names '()))
          (cond
           ((null? cursor) (cons 'ok (reverse names)))
           ((pair? cursor)
            (if (not (symbol? (car cursor)))
                #f
                (loop (cdr cursor) (cons (car cursor) names))))
           ((symbol? cursor) (cons 'ok (reverse (cons cursor names))))
           (else #f))))))

    (define (documentation-parameters-match-arguments? fields names)
      "Report whether parameter NAMES are all present in FIELDS arguments."
      (let ((arguments (documentation-field fields 'arguments)))
        (if (not arguments)
            #t
            (let ((argument-names-result
                   (documentation-argument-names (cdr arguments))))
              (and argument-names-result
                   (let loop ((rest names)
                              (argument-names (cdr argument-names-result)))
                     (cond
                      ((null? rest) #t)
                      ((memq (car rest) argument-names)
                       (loop (cdr rest) argument-names))
                      (else #f))))))))

    (define (documentation-merge-parameters fields value)
      "Return FIELDS merged with parameter metadata VALUE, or #f if malformed."
      (let ((new-names-result (documentation-parameter-names value))
            (existing (documentation-field fields 'parameters)))
        (if (not new-names-result)
            #f
            (let ((new-names (cdr new-names-result)))
              (cond
               ((not (documentation-parameters-match-arguments?
                      fields new-names))
                #f)
               (existing
                (let ((existing-names-result
                       (documentation-parameter-names (cdr existing))))
                  (if (not existing-names-result)
                      #f
                      (let duplicate-loop
                          ((rest new-names)
                           (existing-names (cdr existing-names-result)))
                        (cond
                         ((null? rest)
                          (documentation-set-field
                           fields
                           'parameters
                           (append (cdr existing) value)))
                         ((memq (car rest) existing-names) #f)
                         (else
                          (duplicate-loop
                           (cdr rest)
                           existing-names)))))))
               (else
                (documentation-add-field fields 'parameters value)))))))

    (define (documentation-merge-field fields name value)
      "Return FIELDS merged with NAME/VALUE, or #f if malformed."
      (let ((existing (documentation-field fields name)))
        (cond
         ((eq? name 'documentation)
          (if (not (string? value))
              #f
              (if existing
                  (if (string? (cdr existing))
                      (documentation-set-field
                       fields
                       name
                       (string-append (cdr existing) "\n" value))
                      #f)
                  (documentation-add-field fields name value))))
         ((eq? name 'parameters)
          (documentation-merge-parameters fields value))
         ((memq name documentation-list-field-names)
          (if (not (proper-list? value))
              #f
              (if existing
                  (if (proper-list? (cdr existing))
                      (documentation-set-field
                       fields name (append (cdr existing) value))
                      #f)
                  (documentation-add-field fields name value))))
         (existing #f)
         (else
          (documentation-add-field fields name value)))))

    (define (documentation-merge-fields fields new-fields)
      "Return FIELDS merged with NEW-FIELDS, or #f when malformed."
      (let loop ((rest new-fields) (merged fields))
        (cond
         ((null? rest) merged)
         (else
          (let ((next
                 (documentation-merge-field
                  merged
                  (car (car rest))
                  (cdr (car rest)))))
            (and next (loop (cdr rest) next)))))))

    (define (documentation-rich-vector-fields literal)
      "Return field alist for rich metadata LITERAL, or #f if malformed."
      (let ((items (vector->list literal)))
        (if (null? items)
            #f
            (let loop ((rest items) (fields '()))
              (cond
               ((null? rest) (reverse fields))
               ((not (pair? (car rest))) #f)
               ((not (symbol? (car (car rest)))) #f)
               (else
                (loop (cdr rest)
                      (cons (cons (car (car rest)) (cdr (car rest)))
                            fields))))))))

    (define (documentation-merge-string-run metadata strings)
      "Return METADATA merged with adjacent documentation STRINGS."
      (let ((merged-fields
             (documentation-merge-field
              (documentation-metadata-fields metadata)
              'documentation
              (documentation-join-strings strings))))
        (and merged-fields
             (make-documentation-metadata
              merged-fields
              (documentation-add-origin
               (documentation-metadata-origins metadata)
               'string)))))

    (define (documentation-merge-rich-vector metadata literal)
      "Return METADATA merged with rich vector LITERAL, or #f when malformed."
      (let* ((new-fields (documentation-rich-vector-fields literal))
             (merged-fields
              (and new-fields
                   (documentation-merge-fields
                    (documentation-metadata-fields metadata)
                    new-fields))))
        (and merged-fields
             (make-documentation-metadata
              merged-fields
              (documentation-add-origin
               (documentation-metadata-origins metadata)
               'vector)))))

    (define (documentation-base-metadata retention maybe-formals)
      "Return generated base metadata for RETENTION and MAYBE-FORMALS."
      (if (and (pair? maybe-formals) (not (eq? retention 'none)))
          (documentation-metadata-from-formals (car maybe-formals))
          (make-documentation-metadata '() '())))

    (define (documentation-body-result
             body body-definition-form? retention . maybe-formals)
      "Return `(metadata . body)' after reading documentation literals from BODY."
      (let* ((retention (normalize-docstring-retention retention))
             (retained-base
              (documentation-base-metadata retention maybe-formals))
             (validation-base
              (if (null? maybe-formals)
                  (make-documentation-metadata '() '())
                  (documentation-metadata-from-formals (car maybe-formals)))))
        (let skip-definitions ((cursor body) (definitions '()))
          (if (and (pair? cursor) (body-definition-form? (car cursor)))
              (skip-definitions (cdr cursor) (cons (car cursor) definitions))
              (let scan ((rest cursor)
                         (validation-metadata validation-base)
                         (retained-metadata retained-base)
                         (saw-metadata #f))
                (define (finish final-rest final-retained-metadata)
                  (let* ((has-remaining-expression
                          (and (pair? final-rest)
                               (not (body-definition-form?
                                     (car final-rest)))))
                         (metadata
                          (cond
                           ((and has-remaining-expression
                                 (documentation-metadata-fields-present?
                                  final-retained-metadata))
                            final-retained-metadata)
                           ((documentation-metadata-fields-present?
                             retained-base)
                            retained-base)
                           (else #f)))
                         (rewritten-body
                          (if (and has-remaining-expression saw-metadata)
                              (append (reverse definitions) final-rest)
                              body)))
                    (cons metadata rewritten-body)))
                (cond
                 ((not (pair? rest))
                  (finish rest retained-metadata))
                 ((string? (car rest))
                  (let collect ((cursor rest) (strings '()))
                    (if (and (pair? cursor) (string? (car cursor)))
                        (collect (cdr cursor) (cons (car cursor) strings))
                        (let* ((ordered-strings (reverse strings))
                               (merged-validation
                                (documentation-merge-string-run
                                 validation-metadata
                                 ordered-strings)))
                          (if merged-validation
                              (scan
                               cursor
                               merged-validation
                               (if (memq retention '(full simple))
                                   (documentation-merge-string-run
                                    retained-metadata
                                    ordered-strings)
                                   retained-metadata)
                               #t)
                              (finish cursor retained-metadata))))))
                 ((vector? (car rest))
                  (let ((merged-validation
                         (documentation-merge-rich-vector
                          validation-metadata
                          (car rest))))
                    (if merged-validation
                        (scan (cdr rest)
                              merged-validation
                              (if (eq? retention 'full)
                                  merged-validation
                                  retained-metadata)
                              #t)
                        (finish rest retained-metadata))))
                 (else
                  (finish rest retained-metadata))))))))

    (define (documentation-metadata-from-body
             body body-definition-form? . maybe-formals)
      "Return full documentation metadata from BODY."
      (car (apply documentation-body-result
                  body
                  body-definition-form?
                  'full
                  maybe-formals)))

    (define (second list)
      "Return the second element of LIST for parser helpers."
      (car (cdr list)))

    (define (third list)
      "Return the third element of LIST for parser helpers."
      (car (cdr (cdr list))))

    (define (fourth list)
      "Return the fourth element of LIST for parser helpers."
      (car (cdr (cdr (cdr list)))))

    (define (expect-symbol datum description)
      "Validate that DATUM is a symbol for a named syntax context."
      (if (symbol? datum)
          datum
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    (define (identifier-datum? datum)
      "Report whether DATUM is a symbol or wrapped syntax identifier."
      (or (symbol? datum) (identifier? datum)))

    (define (identifier-datum-name datum)
      "Return the symbolic name from a raw or wrapped identifier."
      (cond
       ((symbol? datum) datum)
       ((identifier? datum) (identifier-name datum))
       (else #f)))

    (define (identifier-key identifier)
      "Return the lookup key for an identifier, preserving macro context."
      (cond
       ((identifier? identifier)
        (let ((context (identifier-context identifier)))
          (if context
              (list 'syntax
                    (syntax-context-id context)
                    (identifier-name identifier))
              (identifier-name identifier))))
       ((symbol? identifier) identifier)
       (else
        (eval-error "expected identifier" identifier))))

    (define (identifier-named? datum name)
      "Report whether DATUM names the given symbol after identifier unwrapping."
      (let ((actual (identifier-datum-name datum)))
        (and actual (eq? actual name))))

    (define (expect-identifier-key datum description)
      "Return an identifier lookup key or raise a syntax-specific error."
      (if (identifier-datum? datum)
          (identifier-key datum)
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    (define (consent-make-empty-environment . maybe-parent)
      "Public constructor for a mutable lexical environment with an optional parent."
      (make-environment
       '()
       (if (null? maybe-parent) #f (car maybe-parent))
       '()))

    (define (frame-cell environment name)
      "Return the cell for NAME in ENVIRONMENT's current frame, or #f."
      (let ((cell (assoc name (environment-frame environment))))
        (if cell (cdr cell) #f)))

    (define (environment-cell environment name)
      "Return the nearest lexical cell for NAME, walking parent environments."
      (let loop ((cursor environment))
        (cond
         ((not cursor) #f)
         ((frame-cell cursor name) => (lambda (cell) cell))
         (else (loop (environment-parent cursor))))))

    (define (environment-cell-imported? environment cell)
      "Report whether CELL is marked imported in ENVIRONMENT or its parents."
      (let environment-loop ((cursor environment))
        (and cursor
             (or (let frame-loop ((frame (environment-frame cursor)))
                   (and (not (null? frame))
                        (or (and (eq? (cdr (car frame)) cell)
                                 (memq (car (car frame))
                                       (environment-imported-names cursor)))
                            (frame-loop (cdr frame)))))
                 (environment-loop (environment-parent cursor))))))

    (define (current-environment-imported? environment name)
      "Report whether NAME is an imported binding in ENVIRONMENT's own frame."
      (memq name (environment-imported-names environment)))

    (define (environment-define! environment name value)
      "Add NAME to ENVIRONMENT's current frame unless it would redefine import."
      (if (current-environment-imported? environment name)
          (eval-error "cannot redefine imported binding" name))
      (set-environment-frame!
       environment
       (cons (cons name (make-cell value))
             (environment-frame environment))))

    (define (environment-set! environment name value)
      "Mutate an existing lexical binding, rejecting unbound and imported names."
      (let ((cell (environment-cell environment name)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!" name))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding" name))
         (else
          (set-cell-value! cell value)))))

    (define (environment-define-or-set! environment name value)
      "Update NAME in the current frame, or define it if no current cell exists."
      (let ((cell (frame-cell environment name)))
        (if cell
            (begin
              (if (current-environment-imported? environment name)
                  (eval-error "cannot redefine imported binding" name))
              (set-cell-value! cell value))
            (environment-define! environment name value))))

    (define (environment-ref environment name)
      "Return NAME's value, rejecting unbound or still-undefined bindings."
      (let ((cell (environment-cell environment name)))
        (if (not cell)
            (eval-error "unbound identifier" name)
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   name)
                  value)))))

    (define (environment-cell-for-identifier environment identifier)
      "Resolve a raw or hygienic identifier to its lexical cell."
      ;; Hygienic identifiers first try their generated lexical key at the use
      ;; site, then fall back to the macro definition environment for free
      ;; template identifiers.
      (cond
       ((identifier? identifier)
        (let ((context (identifier-context identifier)))
          (if context
              (or (environment-cell environment (identifier-key identifier))
                  (let ((definition-environment
                         (syntax-context-value-environment context)))
                    (and definition-environment
                         (environment-cell definition-environment
                                           (identifier-name identifier)))))
              (environment-cell environment (identifier-name identifier)))))
       ((symbol? identifier)
        (environment-cell environment identifier))
       (else #f)))

    (define (environment-ref-identifier environment identifier)
      "Return IDENTIFIER's value after hygienic lookup and undefined checks."
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (if (not cell)
            (eval-error "unbound identifier" (identifier-datum-name identifier))
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   (identifier-datum-name identifier))
                  value)))))

    (define (environment-set-identifier! environment identifier value)
      "Mutate IDENTIFIER's binding after hygienic lookup and import checks."
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!"
                      (identifier-datum-name identifier)))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding"
                      (identifier-datum-name identifier)))
         (else
          (set-cell-value! cell value)))))

    (define (ensure-distinct-names names description)
      "Reject duplicate symbols in NAMES using DESCRIPTION for diagnostics."
      (let loop ((rest names) (seen '()))
        (if (not (null? rest))
            (begin
              (if (memq (car rest) seen)
                  (eval-error
                   (string-append "duplicate identifier in " description)
                   (car rest)))
              (loop (cdr rest) (cons (car rest) seen))))))

    (define (parse-formals formals)
      "Parse lambda formals into required-name and optional-rest metadata."
      (cond
       ((symbol? formals)
        (make-formals '() (identifier-key formals)))
       ((identifier? formals)
        (make-formals '() (identifier-key formals)))
       (else
        (let loop ((cursor formals) (required '()))
          (cond
           ((null? cursor)
            (let ((names (reverse required)))
              (ensure-distinct-names names "lambda formals")
              (make-formals names #f)))
           ((pair? cursor)
            (loop (cdr cursor)
                  (cons (expect-identifier-key (car cursor) "lambda formal")
                        required)))
           ((identifier-datum? cursor)
            (let ((names (reverse required)))
              (ensure-distinct-names
               (append names (list (identifier-key cursor)))
                                     "lambda formals")
              (make-formals names (identifier-key cursor))))
           (else
            (eval-error
             "lambda formals must be an identifier, a proper list, or a dotted list"
             formals)))))))

    ))
