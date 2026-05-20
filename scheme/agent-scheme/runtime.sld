;;; Portable Agent Scheme runtime values and evaluation state.
;;;
;;; This library owns the host-neutral records, lexical environment helpers,
;;; budget accounting, and datum-shape utilities shared by the portable
;;; evaluator passes.

(define-library (agent-scheme runtime)
  (export agent-scheme-default-maximum-steps
          agent-scheme-default-maximum-value-nodes
          agent-scheme-default-maximum-host-callbacks
          agent-scheme-make-empty-environment
          agent-scheme-unspecified
          agent-scheme-unspecified?
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
          make-procedure
          agent-scheme-procedure?
          procedure-formals
          procedure-body
          procedure-environment
          make-primitive-procedure
          agent-scheme-primitive-procedure?
          primitive-procedure-name
          primitive-procedure-function
          primitive-procedure-minimum-arity
          primitive-procedure-maximum-arity
          make-parameter
          agent-scheme-parameter?
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
          make-dynamic-wind-frame
          dynamic-wind-frame?
          dynamic-wind-frame-before
          dynamic-wind-frame-after
          make-agent-scheme-error-object
          agent-scheme-error-object?
          agent-scheme-error-object-message
          agent-scheme-error-object-irritants
          make-agent-scheme-eof-object
          agent-scheme-eof-object?
          agent-scheme-eof-object
          make-agent-scheme-port
          agent-scheme-port?
          agent-scheme-port-medium
          agent-scheme-port-input?
          agent-scheme-port-output?
          agent-scheme-port-textual?
          agent-scheme-port-binary?
          agent-scheme-port-open?
          set-agent-scheme-port-open?!
          agent-scheme-port-source
          agent-scheme-port-position
          set-agent-scheme-port-position!
          agent-scheme-port-contents
          set-agent-scheme-port-contents!
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
          context-syntax-environment
          set-context-syntax-environment!
          context-libraries
          set-context-libraries!
          context-include-paths
          context-include-directory
          set-context-include-directory!
          context-file-paths
          context-policy-actions
          context-policy-confirmation-function
          context-capability-grants
          set-context-capability-grants!
          context-active-capability-grants
          set-context-active-capability-grants!
          context-audit-events
          set-context-audit-events!
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
          (agent-scheme reader))
  (begin
    ;; Default evaluator step budget for one expansion or evaluation run.
    (define agent-scheme-default-maximum-steps 100000)
    ;; Default maximum result value graph size before budget failure.
    (define agent-scheme-default-maximum-value-nodes 100000)
    ;; Default maximum primitive callback count allowed during evaluation.
    (define agent-scheme-default-maximum-host-callbacks 10000)
    ;; Default maximum event-channel records allowed during evaluation.
    (define agent-scheme-default-maximum-events 1000)
    ;; Default maximum reachable value graph size for one event record.
    (define agent-scheme-default-maximum-event-nodes 100000)

    ;; Record type for the singleton unspecified value returned by effect-only
    ;; forms.
    (define-record-type <agent-scheme-unspecified>
      (make-unspecified)
      agent-scheme-unspecified?
      (tag unspecified-tag))

    ;; Singleton value representing Scheme results whose value is unspecified.
    (define agent-scheme-unspecified (make-unspecified))

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

    ;; Record type for compound Scheme procedures and their closure
    ;; environment.
    (define-record-type <procedure>
      (make-procedure formals body environment)
      agent-scheme-procedure?
      (formals procedure-formals)
      (body procedure-body)
      (environment procedure-environment))

    ;; Primitive procedures are the kernel boundary: each call is budgeted as a
    ;; host callback even when the primitive implements pure R7RS behavior.
    (define-record-type <primitive-procedure>
      (make-primitive-procedure name function minimum-arity maximum-arity)
      agent-scheme-primitive-procedure?
      (name primitive-procedure-name)
      (function primitive-procedure-function)
      (minimum-arity primitive-procedure-minimum-arity)
      (maximum-arity primitive-procedure-maximum-arity))

    ;; Record type for parameter procedure state and optional conversion
    ;; function.
    (define-record-type <agent-scheme-parameter>
      (make-parameter value converter)
      agent-scheme-parameter?
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
      (make-continuation procedure dynamic-winds exception-handlers)
      continuation?
      (procedure continuation-procedure)
      (dynamic-winds continuation-dynamic-winds)
      (exception-handlers continuation-exception-handlers))

    ;; Record type for before/after thunks active in dynamic-wind stacks.
    (define-record-type <dynamic-wind-frame>
      (make-dynamic-wind-frame before after)
      dynamic-wind-frame?
      (before dynamic-wind-frame-before)
      (after dynamic-wind-frame-after))

    ;; Record type for Scheme error objects with messages and irritants.
    (define-record-type <agent-scheme-error-object>
      (make-agent-scheme-error-object message irritants)
      agent-scheme-error-object?
      (message agent-scheme-error-object-message)
      (irritants agent-scheme-error-object-irritants))

    ;; Record type for the singleton EOF object used by Agent Scheme ports.
    (define-record-type <agent-scheme-eof-object>
      (make-agent-scheme-eof-object)
      agent-scheme-eof-object?)

    ;; Singleton EOF object returned by Agent Scheme input primitives.
    (define agent-scheme-eof-object (make-agent-scheme-eof-object))

    ;; Portable ports keep backing storage as Scheme data; host-file access is
    ;; still explicit policy surface even though this record is host-neutral.
    (define-record-type <agent-scheme-port>
      ;; MEDIUM separates string, bytevector, host-file, and virtual ports.
      ;; SOURCE/POSITION back input ports; CONTENTS backs output ports.
      (make-agent-scheme-port medium input? output? textual? binary?
                              open? source position contents)
      agent-scheme-port?
      (medium agent-scheme-port-medium)
      (input? agent-scheme-port-input?)
      (output? agent-scheme-port-output?)
      (textual? agent-scheme-port-textual?)
      (binary? agent-scheme-port-binary?)
      (open? agent-scheme-port-open? set-agent-scheme-port-open?!)
      (source agent-scheme-port-source)
      (position agent-scheme-port-position set-agent-scheme-port-position!)
      (contents agent-scheme-port-contents
                set-agent-scheme-port-contents!))

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
                         policy-actions policy-confirmation-function
                         capability-grants active-capability-grants
                         event-count maximum-events maximum-event-nodes
                         audit-events
                         interaction-environment
                         base-syntax-installed next-syntax-id
                         exception-handlers dynamic-winds)
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
      (policy-actions context-policy-actions)
      (policy-confirmation-function context-policy-confirmation-function)
      (capability-grants context-capability-grants
                         set-context-capability-grants!)
      (active-capability-grants context-active-capability-grants
                                set-context-active-capability-grants!)
      (audit-events context-audit-events set-context-audit-events!)
      (interaction-environment context-interaction-environment
                               set-context-interaction-environment!)
      (base-syntax-installed context-base-syntax-installed
                             set-context-base-syntax-installed!)
      (next-syntax-id context-next-syntax-id set-context-next-syntax-id!)
      (exception-handlers context-exception-handlers
                          set-context-exception-handlers!)
      (dynamic-winds context-dynamic-winds set-context-dynamic-winds!))

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

    ;; Return the option value for KEY or DEFAULT when KEY is absent.
    (define (option-ref options key default)
      (let ((cell (assq key options)))
        (if cell (cdr cell) default)))

    ;; Raise an evaluator error with the Agent Scheme diagnostic prefix.
    (define (eval-error message . irritants)
      (apply error
             (string-append "agent-scheme eval error: " message)
             irritants))

    ;; Raise an evaluator budget error with the Agent Scheme diagnostic prefix.
    (define (budget-error message . irritants)
      (apply error
             (string-append "agent-scheme budget error: " message)
             irritants))

    ;; Normalize include-directory options to a stable prefix form.
    (define (normalize-include-directory directory)
      (cond
       ((or (string=? directory "")
            (string=? directory "."))
        "")
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        directory)
       (else
        (string-append directory "/"))))

    ;; Report whether PATH is absolute for include/load path resolution.
    (define (path-absolute? path)
      (and (> (string-length path) 0)
           (char=? (string-ref path 0) #\/)))

    ;; Join DIRECTORY and PATH unless PATH is already absolute.
    (define (path-join directory path)
      (cond
       ((or (string=? directory "") (path-absolute? path))
        path)
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        (string-append directory path))
       (else
        (string-append directory "/" path))))

    ;; Split PATH on slash characters, preserving empty components for absolute
    ;; path detection while letting normalization discard redundant separators.
    (define (path-split path)
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

    ;; Join path PARTS with slash separators.
    (define (path-join-parts parts)
      (cond
       ((null? parts) "")
       ((null? (cdr parts)) (car parts))
       (else
        (string-append (car parts) "/" (path-join-parts (cdr parts))))))

    ;; Resolve . and .. path components without consulting the host filesystem.
    (define (path-normalize path)
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

    ;; Return FIELD from DATUM, or #f when it is absent.
    (define (capability-field datum field)
      (let ((entry (and (pair? datum) (assq field (cdr datum)))))
        (if entry entry #f)))

    ;; Return the first value for FIELD from DATUM, or #f.
    (define (capability-field-value datum field)
      (let ((entry (capability-field datum field)))
        (if (and entry (pair? (cdr entry))) (cadr entry) #f)))

    ;; Return every value for FIELD from DATUM.
    (define (capability-field-values datum field)
      (let ((entry (capability-field datum field)))
        (if entry (cdr entry) '())))

    ;; Flatten a Scheme field that may store its values as one nested list.
    (define (capability-flatten-values values)
      (if (and (pair? values)
               (null? (cdr values))
               (list? (car values))
               (not (null? (car values))))
          (car values)
          values))

    ;; Return the scope clause named NAME from GRANT.
    (define (capability-scope-clause grant name)
      (let ((scope (capability-field-values grant 'scope)))
        (let loop ((rest scope))
          (cond
           ((null? rest) #f)
           ((and (pair? (car rest)) (eq? (caar rest) name)) (car rest))
           (else (loop (cdr rest)))))))

    ;; Return the first scope value named NAME from GRANT.
    (define (capability-scope-value grant name)
      (let ((clause (capability-scope-clause grant name)))
        (if (and clause (pair? (cdr clause))) (cadr clause) #f)))

    ;; Return flattened scope values named NAME from GRANT.
    (define (capability-scope-values grant name)
      (let ((clause (capability-scope-clause grant name)))
        (if clause (capability-flatten-values (cdr clause)) '())))

    ;; Report whether GRANT is an active file-domain grant.
    (define (file-capability-grant? grant)
      (and (pair? grant)
           (eq? (car grant) 'capability-grant)
           (eq? (capability-field-value grant 'domain) 'file)))

    ;; Report whether GRANT currently has active status.
    (define (capability-grant-active? grant)
      (let ((status (capability-field-value grant 'status)))
        (or (not status) (eq? status 'active))))

    ;; Report whether GRANT authorizes OPERATION.
    (define (file-capability-operation? grant operation)
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (eq? (car operations) operation)
                 (loop (cdr operations))))))

    ;; Return file-domain grants from CONTEXT.
    (define (file-capability-grants context)
      (let loop ((grants (context-capability-grants context)) (kept '()))
        (cond
         ((null? grants) (reverse kept))
         ((file-capability-grant? (car grants))
          (loop (cdr grants) (cons (car grants) kept)))
         (else
          (loop (cdr grants) kept)))))

    ;; Return a synthetic file grant for legacy allow-list PATHS.
    (define (legacy-file-capability-grants paths operation)
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

    ;; Test whether TEXT begins with PREFIX.
    (define (string-prefix? prefix text)
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref text index))
                        (loop (+ index 1))))))))

    ;; Remove a single trailing slash from PATH for prefix checks.
    (define (strip-trailing-slash path)
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    ;; Report whether TEXT contains NEEDLE.
    (define (string-contains? text needle)
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    ;; Report whether FILENAME names a non-local resource outside file grants.
    (define (remote-file-path? filename)
      (string-contains? filename "://"))

    ;; Return the effect class for a file capability operation.
    (define (file-capability-effect operation)
      (if (memq operation '(write create delete))
          'host-file-mutation
          'read-only-observation))

    ;; Report whether PATH is equal to or nested inside ROOT.
    (define (path-contained? path root)
      (let* ((normalized-path (path-normalize path))
             (normalized-root (strip-trailing-slash (path-normalize root)))
             (root-directory (string-append normalized-root "/")))
        (or (string=? normalized-path normalized-root)
            (string-prefix? root-directory normalized-path))))

    ;; Return normalized allowed roots described by GRANT.
    (define (file-capability-roots grant context)
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

    ;; Return a matching grant for PATH and OPERATION, or a denial reason.
    (define (file-capability-match grants path operation context)
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

    ;; Return a portable file capability request datum.
    (define (file-capability-request filename path operation binding)
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

    ;; Return a portable Scheme-readable file handle datum.
    (define (file-capability-handle path grant)
      (list 'handle
            (list 'id (string-append "file:" path))
            (list 'kind 'file)
            (list 'domain 'file)
            (list 'path path)
            (list 'grant (capability-field-value grant 'id))
            (list 'status 'live)))

    ;; Record DENIAL for REQUEST and raise a portable evaluator error.
    (define (deny-file-capability! context request operation grant reason)
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

    ;; Authorize FILENAME for file OPERATION and return authorization data.
    (define (authorize-file-capability
             filename context operation binding legacy-paths)
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

    ;; Return the authorized normalized host path from AUTHORIZATION.
    (define (file-authorization-path authorization)
      (cadr (assq 'path authorization)))

    ;; Record the result of an authorized file capability operation.
    (define (audit-file-capability-result!
             context authorization result error?)
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

    ;; Return a portable code-loading request datum.
    (define (code-loading-request authorization binding)
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

    ;; Authorize evaluation of source forms read by a file capability request.
    (define (authorize-code-loading authorization context binding)
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

    ;; Record the result of a code-loading capability operation.
    (define (audit-code-loading-result!
             context authorization result error?)
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

    ;; Resolve relative include paths against the active include directory.
    (define (normalize-include-paths paths directory)
      (map (lambda (path)
             (path-normalize (path-join directory path)))
           paths))

    ;; Create a fresh evaluation context from user option overrides.
    (define (new-eval-context options)
      (let ((include-directory
             (normalize-include-directory
              (option-ref options 'include-directory "."))))
      (make-eval-context
       0
       (if (assq 'max-steps options)
           (option-ref options 'max-steps agent-scheme-default-maximum-steps)
           (option-ref options
                       'max-non-tail-steps
                       agent-scheme-default-maximum-steps))
       (option-ref options
                   'max-value-nodes
                   agent-scheme-default-maximum-value-nodes)
       0
       (option-ref options
                   'max-host-callbacks
                   agent-scheme-default-maximum-host-callbacks)
       (make-syntax-environment '() #f '())
       '()
       (normalize-include-paths
        (option-ref options 'include-paths '())
        include-directory)
       include-directory
       (normalize-include-paths
        (option-ref options 'file-paths '())
        include-directory)
       (option-ref options 'policy-actions '())
       (option-ref options 'policy-confirmation-function #f)
       (option-ref options 'capability-grants '())
       '()
       0
       (option-ref options
                   'max-events
                   agent-scheme-default-maximum-events)
       (option-ref options
                   'max-event-nodes
                   agent-scheme-default-maximum-event-nodes)
       '()
       #f
       #f
       0
       '()
       '())))

    ;; Record a Scheme-readable audit EVENT with FIELDS in CONTEXT.
    (define (record-audit-event! context event fields)
      (let ((entry (cons 'audit-entry
                         (cons (list 'event event) fields))))
        (set-context-audit-events!
         context
         (cons entry (context-audit-events context)))
        entry))

    ;; Record an ordered event-channel EVENT after enforcing event budgets.
    (define (record-agent-event! context event)
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

    ;; Charge one evaluator step against the active step budget.
    (define (note-step! context)
      (set-context-steps! context (+ (context-steps context) 1))
      (if (> (context-steps context) (context-maximum-steps context))
          (budget-error "evaluation step budget exceeded"
                        (context-maximum-steps context))))

    ;; Charge one primitive callback against the host-callback budget.
    (define (note-host-callback! context primitive)
      (set-context-host-callbacks!
       context
       (+ (context-host-callbacks context) 1))
      (if (> (context-host-callbacks context)
             (context-maximum-host-callbacks context))
          (budget-error "host callback budget exceeded"
                        (primitive-procedure-name primitive))))

    ;; Count the reachable nodes in VALUE while tolerating cycles.
    (define (value-node-count value seen)
      (cond
       ((or (boolean? value)
            (null? value)
            (symbol? value)
            (identifier? value)
            (char? value)
            (agent-scheme-number? value)
            (agent-scheme-unspecified? value)
            (agent-scheme-procedure? value)
            (agent-scheme-primitive-procedure? value)
            (agent-scheme-parameter? value)
            (continuation? value)
            (agent-scheme-error-object? value)
            (agent-scheme-eof-object? value)
            (agent-scheme-port? value)
            (environment-specifier? value)
            (string-output-port? value)
            (agent-scheme-record-type? value))
        1)
       ((agent-scheme-record? value)
        (if (memq value seen)
            0
            (let ((fields (agent-scheme-record-fields value)))
              (let loop ((index 0) (count 1))
                (if (= index (vector-length fields))
                    count
                    (loop (+ index 1)
                          (+ count
                             (value-node-count
                              (vector-ref fields index)
                              (cons value seen)))))))))
       ((multiple-values? value)
        (+ 1
           (let loop ((rest (multiple-values-values value)) (count 0))
             (if (null? rest)
                 count
                 (loop (cdr rest)
                       (+ count
                          (value-node-count (car rest) seen)))))))
       ((string? value)
        (+ 1 (string-length value)))
       ((bytevector? value)
        (+ 1 (bytevector-length value)))
       ((pair? value)
        (if (memq value seen)
            0
            (+ 1
               (value-node-count (car value) (cons value seen))
               (value-node-count (cdr value) (cons value seen)))))
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
                            (cons value seen))))))))
       (else
        (eval-error "unsupported Scheme value" value))))

    ;; Reject VALUE when its reachable node count exceeds the result budget.
    (define (check-value-budget value context)
      (let ((count (value-node-count value '())))
        (if (> count (context-maximum-value-nodes context))
            (budget-error "value node budget exceeded"
                          count
                          (context-maximum-value-nodes context))))
      value)

    ;; Unpack a single or multiple-value result into a list.
    (define (values-list value)
      (if (multiple-values? value)
          (multiple-values-values value)
          (list value)))

    ;; Require VALUE to contain exactly one Scheme value.
    (define (single-value value description)
      (let ((values (values-list value)))
        (if (not (= (length values) 1))
            (eval-error
             (string-append description " expected one value")
             (length values)))
        (car values)))

    ;; Default continuation that returns its input value unchanged.
    (define (identity-continuation value)
      value)

    ;; Invoke a continuation procedure with VALUE.
    (define (continue continuation value)
      (continuation value))

    ;; Package continuation arguments as one value or multiple values.
    (define (continuation-value arguments)
      (if (= (length arguments) 1)
          (car arguments)
          (make-multiple-values arguments)))

    ;; Return DATUM as a proper list or raise an evaluator error.
    (define (proper-list-elements datum description)
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else
          (eval-error
           (string-append description " must be a proper list"))))))

    ;; Return the second element of LIST for parser helpers.
    (define (second list)
      (car (cdr list)))

    ;; Return the third element of LIST for parser helpers.
    (define (third list)
      (car (cdr (cdr list))))

    ;; Return the fourth element of LIST for parser helpers.
    (define (fourth list)
      (car (cdr (cdr (cdr list)))))

    ;; Validate that DATUM is a symbol for a named syntax context.
    (define (expect-symbol datum description)
      (if (symbol? datum)
          datum
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    ;; Report whether DATUM is a symbol or wrapped syntax identifier.
    (define (identifier-datum? datum)
      (or (symbol? datum) (identifier? datum)))

    ;; Return the symbolic name from a raw or wrapped identifier.
    (define (identifier-datum-name datum)
      (cond
       ((symbol? datum) datum)
       ((identifier? datum) (identifier-name datum))
       (else #f)))

    ;; Return the lookup key for an identifier, preserving macro context.
    (define (identifier-key identifier)
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

    ;; Report whether DATUM names the given symbol after identifier unwrapping.
    (define (identifier-named? datum name)
      (let ((actual (identifier-datum-name datum)))
        (and actual (eq? actual name))))

    ;; Return an identifier lookup key or raise a syntax-specific error.
    (define (expect-identifier-key datum description)
      (if (identifier-datum? datum)
          (identifier-key datum)
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    ;; Public constructor for a mutable lexical environment with an optional
    ;; parent.
    (define (agent-scheme-make-empty-environment . maybe-parent)
      (make-environment
       '()
       (if (null? maybe-parent) #f (car maybe-parent))
       '()))

    ;; Return the cell for NAME in ENVIRONMENT's current frame, or #f.
    (define (frame-cell environment name)
      (let ((cell (assoc name (environment-frame environment))))
        (if cell (cdr cell) #f)))

    ;; Return the nearest lexical cell for NAME, walking parent environments.
    (define (environment-cell environment name)
      (let loop ((cursor environment))
        (cond
         ((not cursor) #f)
         ((frame-cell cursor name) => (lambda (cell) cell))
         (else (loop (environment-parent cursor))))))

    ;; Report whether CELL is marked imported in ENVIRONMENT or its parents.
    (define (environment-cell-imported? environment cell)
      (let environment-loop ((cursor environment))
        (and cursor
             (or (let frame-loop ((frame (environment-frame cursor)))
                   (and (not (null? frame))
                        (or (and (eq? (cdr (car frame)) cell)
                                 (memq (car (car frame))
                                       (environment-imported-names cursor)))
                            (frame-loop (cdr frame)))))
                 (environment-loop (environment-parent cursor))))))

    ;; Report whether NAME is an imported binding in ENVIRONMENT's own frame.
    (define (current-environment-imported? environment name)
      (memq name (environment-imported-names environment)))

    ;; Add NAME to ENVIRONMENT's current frame unless it would redefine import.
    (define (environment-define! environment name value)
      (if (current-environment-imported? environment name)
          (eval-error "cannot redefine imported binding" name))
      (set-environment-frame!
       environment
       (cons (cons name (make-cell value))
             (environment-frame environment))))

    ;; Mutate an existing lexical binding, rejecting unbound and imported names.
    (define (environment-set! environment name value)
      (let ((cell (environment-cell environment name)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!" name))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding" name))
         (else
          (set-cell-value! cell value)))))

    ;; Update NAME in the current frame, or define it if no current cell exists.
    (define (environment-define-or-set! environment name value)
      (let ((cell (frame-cell environment name)))
        (if cell
            (begin
              (if (current-environment-imported? environment name)
                  (eval-error "cannot redefine imported binding" name))
              (set-cell-value! cell value))
            (environment-define! environment name value))))

    ;; Return NAME's value, rejecting unbound or still-undefined bindings.
    (define (environment-ref environment name)
      (let ((cell (environment-cell environment name)))
        (if (not cell)
            (eval-error "unbound identifier" name)
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   name)
                  value)))))

    ;; Resolve a raw or hygienic identifier to its lexical cell.
    (define (environment-cell-for-identifier environment identifier)
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

    ;; Return IDENTIFIER's value after hygienic lookup and undefined checks.
    (define (environment-ref-identifier environment identifier)
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (if (not cell)
            (eval-error "unbound identifier" (identifier-datum-name identifier))
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   (identifier-datum-name identifier))
                  value)))))

    ;; Mutate IDENTIFIER's binding after hygienic lookup and import checks.
    (define (environment-set-identifier! environment identifier value)
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

    ;; Reject duplicate symbols in NAMES using DESCRIPTION for diagnostics.
    (define (ensure-distinct-names names description)
      (let loop ((rest names) (seen '()))
        (if (not (null? rest))
            (begin
              (if (memq (car rest) seen)
                  (eval-error
                   (string-append "duplicate identifier in " description)
                   (car rest)))
              (loop (cdr rest) (cons (car rest) seen))))))

    ;; Parse lambda formals into required-name and optional-rest metadata.
    (define (parse-formals formals)
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
