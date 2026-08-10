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
          consent-default-maximum-source-metadata
          consent-default-maximum-host-callbacks
          consent-version-components
          consent-version
          consent-set-library-search-directories!
          consent-library-search-directory-list
          consent-set-library-system-directories!
          consent-library-system-directory-list
          consent-set-library-user-directories!
          consent-library-user-directory-list
          consent-register-embedded-source!
          consent-embedded-source-ref
          consent-register-native-library!
          consent-native-library-ref
          consent-native-library-documentation-ref
          consent-install-native-applier!
          consent-native-applier-ref
          consent-host-datum->consent-datum
          consent-make-empty-environment
          consent-unspecified
          consent-unspecified?
          make-undefined
          undefined?
          undefined
          make-cell
          cell?
          cell-value
          context-cell-set!
          make-environment
          environment?
          environment-frame
          set-environment-frame!
          environment-parent
          environment-imported-names
          set-environment-imported-names!
          environment-datum-heap
          context-use-environment-datum-heap!
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
          procedure-syntax-environment
          procedure-documentation
          make-primitive-procedure
          consent-primitive-procedure?
          primitive-procedure-name
          primitive-procedure-function
          primitive-procedure-minimum-arity
          primitive-procedure-maximum-arity
          primitive-procedure-documentation
          set-primitive-procedure-documentation!
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
          context-maximum-source-metadata
          context-value-nodes
          set-context-value-nodes!
          context-interned-symbols
          set-context-interned-symbols!
          context-maximum-interned-symbols
          set-context-maximum-interned-symbols!
          context-symbol-table
          set-context-symbol-table!
          context-datum-heap
          set-context-datum-heap!
          context-host-callbacks
          set-context-host-callbacks!
          context-maximum-host-callbacks
          context-event-count
          set-context-event-count!
          context-maximum-events
          context-maximum-event-nodes
          set-context-maximum-steps!
          set-context-maximum-value-nodes!
          set-context-maximum-source-metadata!
          set-context-maximum-host-callbacks!
          set-context-maximum-events!
          context-output-bytes
          set-context-output-bytes!
          context-maximum-output-bytes
          set-context-maximum-output-bytes!
          context-maximum-wall-time-ms
          set-context-maximum-wall-time-ms!
          context-wall-clock
          set-context-wall-clock!
          context-wall-start
          set-context-wall-start!
          context-exhaustion-reason
          set-context-exhaustion-reason!
          context-syntax-environment
          set-context-syntax-environment!
          context-libraries
          set-context-libraries!
          context-native-binding-cache
          set-context-native-binding-cache!
          context-source-copy-count
          context-source-copy-set-fresh!
          context-source-copy-set!
          context-source-copy-source-ref
          context-copy-datum-source!
          context-include-paths
          context-include-directory
          set-context-include-directory!
          context-file-paths
          context-internal-libraries-allowed?
          context-docstring-retention
          context-boundary-contract-checking
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
          context-command-line
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
          context-reader-options
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
          record-context-event!
          note-step!
          note-host-callback!
          note-interned-symbol!
          note-value-allocation!
          value-node-count
          charge-value-allocation!
          charge-string-allocation!
          charge-bytevector-allocation!
          charge-vector-allocation!
          charge-list-allocation!
          charge-literal!
          check-value-budget
          note-output!
          check-wall-time!
          budget-spec-ref
          budget-spec-dimensions
          budget-ceiling-snapshot
          budget-tighten!
          budget-restore!
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
          (only (scheme process-context)
                get-environment-variable)
          (consent version)
          (consent character)
          (consent datum)
          (consent identity-map)
          (consent reader)
          (consent symbol)
          (consent symbol-boundary)
          (agent redaction))
  (begin
    ;; Preserve host operations for implementation identity checks.
    (define host-memq memq)
    ;; Look up private host metadata without mixed-symbol semantics.
    (define host-assq assq)
    ;; Look up private host datums without mixed-symbol semantics.
    (define host-assoc assoc)

    ;; Runtime metadata crosses between host literals and owned datums.
    (define runtime-symbol? consent-host-symbol?)
    ;; Read runtime symbol names across the owned/bootstrap boundary.
    (define runtime-symbol-name consent-host-symbol-name)
    ;; Compare runtime names across the owned/bootstrap boundary.
    (define runtime-symbol-eq? consent-host-symbol-eq?)
    ;; Search runtime name lists across the owned/bootstrap boundary.
    (define runtime-memq consent-host-symbol-memq)
    ;; Look up runtime fields across the owned/bootstrap boundary.
    (define runtime-assq consent-host-symbol-assq)
    ;; Look up runtime datums across the owned/bootstrap boundary.
    (define runtime-assoc consent-host-symbol-assoc)

    ;; Default evaluator step budget for one expansion or evaluation run.
    (define consent-default-maximum-steps 100000)
    ;; Default cumulative value-node allocation budget for one evaluation run.
    ;; Value budgets are charged at allocation, so this bounds the total nodes
    ;; a
    ;; run may construct rather than the size of any single result; it is sized
    ;; well above the comprehensive self-hosted suite's per-run peak (~0.78M
    ;; nodes) while still tripping a runaway bulk allocation.
    (define consent-default-maximum-value-nodes 10000000)
    ;; Default maximum evaluated `string->symbol' interning operations for one
    ;; evaluation run. Each call charges one unit, and because a call interns
    ;; at
    ;; most one new symbol this bounds the symbols a run can add to the global
    ;; intern table -- a resource-exhaustion vector that untrusted evaluated
    ;; code
    ;; such as a `(string->symbol (number->string i))' loop would otherwise
    ;; grow
    ;; without limit. Sized well above legitimate per-run symbol generation
    ;; while
    ;; still tripping a runaway flood; reader-created identifiers are bounded
    ;; by
    ;; the reader's node budgets rather than this dimension.
    (define consent-default-maximum-interned-symbols 1000000)
    ;; Default maximum portable source metadata attachments admitted by a run.
    ;; Owned notes follow object lifetime; legacy host syntax uses the bounded
    ;; bootstrap side table.
    (define consent-default-maximum-source-metadata 10000000)
    ;; Default maximum primitive callback count allowed during evaluation.
    (define consent-default-maximum-host-callbacks 10000)
    ;; Default maximum event-channel records allowed during evaluation.
    (define consent-default-maximum-events 1000)
    ;; Default maximum reachable value graph size for one event record.
    (define consent-default-maximum-event-nodes 100000)
    ;; Default maximum printed-output bytes a single evaluation run may emit.
    ;; Output is charged at each port write, so this bounds the cumulative
    ;; characters a run may display/write across all in-memory and streaming
    ;; ports. It is generous enough for the self-hosted suite's output while a
    ;; runaway unbounded printing loop still trips it.
    (define consent-default-maximum-output-bytes 10485760)
    ;; Default wall-time budget in milliseconds. #f leaves wall time unbounded
    ;; so ordinary and parity runs never read a host clock and stay
    ;; deterministic; a caller opts in by supplying `max-wall-time-ms'.
    (define consent-default-maximum-wall-time-ms #f)

    (define (consent-path-list-add-segment text start end result)
      "Cons PATH segment TEXT[START, END) to RESULT when non-empty."
      (if (= start end)
          result
          (cons (substring text start end) result)))

    (define (consent-split-path-list text)
      "Split a colon-separated host path list into non-empty segments."
      (let ((length (string-length text)))
        (let loop ((index 0)
                   (start 0)
                   (result '()))
          (cond
           ((= index length)
            (reverse
             (consent-path-list-add-segment text start index result)))
           ((char=? (string-ref text index) #\:)
            (loop (+ index 1)
                  (+ index 1)
                  (consent-path-list-add-segment text start index result)))
           (else
            (loop (+ index 1) start result))))))

    (define (consent-environment-library-search-directories)
      "Return host-provided library search roots from CONSENT_LIBRARY_PATH."
      (cond-expand
       (consent
        '())
       (else
        (let ((value (get-environment-variable "CONSENT_LIBRARY_PATH")))
          (if (and value (< 0 (string-length value)))
              (consent-split-path-list value)
              '())))))

    ;; Host-injected library/source resolution context (host/core boundary).
    ;; The portable core reads its prelude, syntax prelude, and source-backed
    ;; libraries by trying, for each logical relative path, every configured
    ;; search-directory prefix in order, then the core's built-in cwd-relative
    ;; defaults, then embedded source. A compiled or installed host injects its
    ;; CONSENT_LIBRARY_PATH, datadir, and executable-relative directories here
    ;; at
    ;; startup, where host facilities exist. Embedded source is the
    ;; zero-dependency floor, consulted only when no on-disk copy is found.
    (define consent-library-system-directories
      (consent-environment-library-search-directories))

    ;; User-provided manifest roots layered after system roots by default.
    (define consent-library-user-directories '())

    (define (consent-set-library-system-directories! directories)
      "Replace host-injected system library roots, highest precedence first."
      #((parameters
         (directories (type (list-of string))
          (description ("List of system library root paths."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! consent-library-system-directories directories)
      consent-unspecified)

    (define (consent-library-system-directory-list)
      "Return the host-injected system library root prefixes."
      #((parameters)
        (returns (type list)
         (description ("The current list of system library root prefixes.")))
        (effects state-read))
      consent-library-system-directories)

    (define (consent-set-library-user-directories! directories)
      "Replace configured user library roots, highest precedence first."
      #((parameters
         (directories (type (list-of string))
          (description ("List of user library root paths."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! consent-library-user-directories directories)
      consent-unspecified)

    (define (consent-library-user-directory-list)
      "Return configured user library root prefixes."
      #((parameters)
        (returns (type list)
         (description ("The current list of user library root prefixes.")))
        (effects state-read))
      consent-library-user-directories)

    (define (consent-set-library-search-directories! directories)
      "Replace system library roots and clear user roots."
      #((parameters
         (directories (type (list-of string))
          (description ("List of system library root path strings."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! consent-library-system-directories directories)
      (set! consent-library-user-directories '())
      consent-unspecified)

    (define (consent-library-search-directory-list)
      "Return the combined system and user library root prefixes."
      #((parameters)
        (returns (type list)
         (description
          ("The current list of system and user library root prefixes.")))
        (effects state-read))
      (append consent-library-system-directories
              consent-library-user-directories))

    ;; Embedded runtime source registered by a compiled host's linked-in
    ;; `(consent embedded-source)' module: an alist of logical-relative-path to
    ;; source text. Empty for interpreted/source runs.
    (define consent-embedded-source-entries '())

    (define (consent-register-embedded-source! relative-path text)
      "Register embedded source TEXT for logical RELATIVE-PATH (the"
      "zero-dependency floor)."
      #((parameters
         (relative-path (type string)
          (description
            ("Logical relative path naming the embedded source entry.")))
         (text (type string)
          (description "Source text to register for that path.")))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! consent-embedded-source-entries
            (cons (cons relative-path text) consent-embedded-source-entries))
      consent-unspecified)

    (define (consent-embedded-source-ref relative-path)
      "Return registered embedded source text for RELATIVE-PATH, or #f when ab\
sent."
      #((parameters
         (relative-path (type string)
          (description
           ("Logical relative path to look up in the embedded-source"
             "registry."))))
        (returns (type (or string boolean))
         (description
          ("The registered source text string, or #f when no entry"
            "exists.")))
        (effects state-read))
      (let ((entry (runtime-assoc relative-path
        consent-embedded-source-entries)))
        (and entry (cdr entry))))

    ;; Native-library registry: a compiled host's generated main registers,
    ;; once
    ;; at startup, name->value tables for the internal libraries linked into
    ;; the
    ;; executable. Under the internal-libraries grant the resolver binds those
    ;; imports to the compiled modules directly instead of re-interpreting
    ;; their
    ;; source, which is what lets the product binary serve as its own host
    ;; runner at native speed. Empty for interpreted/source runs, which keep
    ;; the
    ;; source-loading path.
    (define consent-native-library-entries '())
    ;; Source documentation specs emitted beside compiled library bindings.
    (define consent-native-library-documentation-entries '())
    (define (consent-register-native-library!
             key bindings . maybe-documentation)
      "Register compiled BINDINGS and optional source documentation for KEY."
      #((parameters
         (key (type (list-of (or symbol exact-integer)))
          (description
           ("Library key identifying the internal library being"
             "registered.")))
         (bindings (type list)
          (description
           ("Alist of (name . value) entries exported by the native"
             "library.")))
         (maybe-documentation (type list)
          (description
           ("Optional singleton list containing an alist from export"
             "names to `(formals documentation-literals)' specs."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! consent-native-library-entries
            (cons (cons key bindings) consent-native-library-entries))
      (if (pair? maybe-documentation)
          (set! consent-native-library-documentation-entries
                (cons
                 (cons key (car maybe-documentation))
                 consent-native-library-documentation-entries)))
      consent-unspecified)

    (define (consent-native-library-ref key)
      "Return the native bindings registered for library KEY, or #f when absen\
t."
      #((parameters
         (key (type (list-of (or symbol exact-integer)))
          (description
            ("Library key to look up in the native-library registry."))))
        (returns (type (or list boolean))
         (description
          ("The registered (name . value) bindings alist, or #f when"
            "absent.")))
        (effects state-read))
      (let ((entry (runtime-assoc key consent-native-library-entries)))
        (and entry (cdr entry))))

    (define (consent-native-library-documentation-ref key name)
      "Return compiled source documentation specification for NAME in KEY."
      #((parameters
         (key (type (list-of (or symbol exact-integer)))
          (description
            "Library key to look up in the documentation registry."))
         (name (type symbol)
          (description "Export name whose compiled documentation is sought.")))
        (returns (type (or list boolean))
         (description
          ("The compiled `(formals documentation-literals)' specification,"
            "or #f when no specification is registered.")))
        (effects state-read))
      (let* ((library-entry
              (runtime-assoc
               key
               consent-native-library-documentation-entries))
             (spec-entry
              (and library-entry
                   (runtime-assq name (cdr library-entry))))
             (spec (and spec-entry (cdr spec-entry))))
        (and
         spec
         (pair? spec)
         (pair? (cdr spec))
         spec)))

    ;; Native applier hook: installed by the interpreter at load time so the
    ;; library layer can apply interpreted closures that a program passes as
    ;; callbacks into natively bound library procedures.
    (define consent-native-applier-procedure #f)

    (define (consent-install-native-applier! applier)
      "Install APPLIER, called as (APPLIER procedure arguments context), for"
      "native callbacks."
      #((parameters
         (applier (type procedure)
          (description
           ("Procedure applying interpreted closures, called as"
             "(applier procedure arguments context)."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (set! consent-native-applier-procedure applier)
      consent-unspecified)

    (define (consent-native-applier-ref)
      "Return the installed native callback applier, or #f when absent."
      #((parameters)
        (returns (type (or procedure boolean))
         (description
          ("The installed native callback applier procedure, or #f"
            "when none is installed.")))
        (effects state-read))
      consent-native-applier-procedure)

    (define (consent-version-components)
      "Return the Consent Scheme version as exact non-negative host integers."
      #((parameters)
        (returns (type list)
         (description
          ("A list of exact non-negative host integers naming the"
            "version components.")))
        (effects pure))
      (cdr consent-version-datum))

    (define (consent-version)
      "Return the canonical Scheme-readable Consent Scheme version datum."
      #((parameters)
        (returns (type exact-integer)
         (description
          ("The version datum: a tag followed by canonical-integer"
            "version components.")))
        (effects pure))
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
      (make-cell-record value owned-slots)
      cell?
      (value raw-cell-value)
      (owned-slots cell-owned-slots set-cell-owned-slots!))

    (define (make-cell value . maybe-context)
      "Return private lexical storage initialized to VALUE."
      #((parameters
         (value . "Initial stored value.")
         (maybe-context (type list)
          (description "Zero or one evaluation context owning the cell.")))
        (returns (type cell) (description "Fresh lexical cell."))
        (effects allocation error))
      (make-cell-record
       value
       (if (null? maybe-context)
           #f
           (consent-datum-make-internal-slots
            (context-datum-heap (car maybe-context))
            'cell
            (list value)))))

    (define (cell-value cell)
      "Return CELL's current value from owned or bootstrap storage."
      #((parameters (cell (type cell) (description "Cell to inspect.")))
        (returns (type any) (description "Current stored value."))
        (effects state-read error))
      (let ((slots (cell-owned-slots cell)))
        (if slots
            (consent-datum-internal-slot-ref slots 0)
            (raw-cell-value cell))))

    (define (context-cell-set! context cell operation value)
      "Set CELL to VALUE through CONTEXT's datum-heap mutation gateway."
      #((parameters
         (context (type eval-context)
          (description "Evaluation context whose heap owns the mutation."))
         (cell (type cell) (description "Lexical cell to mutate."))
         (operation (type symbol)
          (description "Mutation observer operation tag."))
         (value . "Replacement binding value."))
        (returns . "The unspecified value.")
        (effects allocation state-write error))
      (let* ((heap (context-datum-heap context))
             (slots
              (or (cell-owned-slots cell)
                  (let ((created
                         (consent-datum-make-internal-slots
                          heap 'cell (list (raw-cell-value cell)))))
                    (set-cell-owned-slots! cell created)
                    created))))
        (consent-datum-internal-slot-set!
         heap slots operation 0 value)))

    ;; Value environments are internal mutable frames; imported names mark the
    ;; current frame bindings that Scheme source cannot redefine or mutate.
    (define-record-type <environment>
      ;; FRAME maps lexical keys to mutable cells.  IMPORTED-NAMES marks
      ;; current-frame imports that Scheme code may not redefine or mutate.
      (make-environment-record frame parent imported-names datum-heap)
      environment?
      (frame environment-frame set-environment-frame!)
      (parent environment-parent)
      (imported-names environment-imported-names
                      set-environment-imported-names!)
      (datum-heap environment-datum-heap set-environment-datum-heap!))

    (define (make-environment frame parent imported-names . maybe-heap)
      "Return a private lexical environment with inherited heap ownership."
      #((parameters
         (frame (type list) (description "Initial binding frame."))
         (parent (type (or environment boolean))
          (description "Parent environment or #f."))
         (imported-names (type list)
          (description "Names protected as imported bindings."))
         (maybe-heap (type list)
          (description "Zero or one explicit datum heap.")))
        (returns (type environment)
         (description "Fresh lexical environment."))
        (effects allocation))
      (make-environment-record
       frame
       parent
       imported-names
       (if (null? maybe-heap)
           (and parent (environment-datum-heap parent))
           (car maybe-heap))))

    (define (environment-effective-datum-heap environment)
      "Return ENVIRONMENT's nearest owned datum heap, or #f."
      (let loop ((cursor environment))
        (and cursor
             (or (environment-datum-heap cursor)
                 (loop (environment-parent cursor))))))

    (define (attach-environment-datum-heap! environment heap)
      "Attach HEAP to unowned frames in ENVIRONMENT's parent chain."
      (let loop ((cursor environment))
        (if cursor
            (let ((current (environment-datum-heap cursor)))
              (if (and current (not (eq? current heap)))
                  (error "environment belongs to another datum heap"))
              (if (not current)
                  (set-environment-datum-heap! cursor heap))
              (loop (environment-parent cursor)))))
      heap)

    (define (context-use-environment-datum-heap! context environment)
      "Make CONTEXT and ENVIRONMENT share one persistent datum heap."
      #((parameters
         (context (type eval-context)
          (description "Evaluation context to align."))
         (environment (type environment)
          (description "Persistent lexical environment to align.")))
        (returns (type datum-heap) (description "The shared heap."))
        (effects state-write error))
      (let ((heap
             (or (environment-effective-datum-heap environment)
                 (context-datum-heap context))))
        (attach-environment-datum-heap! environment heap)
        (set-context-datum-heap! context heap)
        heap))

    (define (ensure-environment-context-heap! environment context)
      "Reject a CONTEXT that conflicts with ENVIRONMENT's persistent heap."
      "Unowned source-library and template environments remain reusable; only"
      "an explicit `context-use-environment-datum-heap!' call makes an"
      "environment persistent across evaluations."
      (let ((heap (environment-effective-datum-heap environment)))
        (if (and heap (not (eq? heap (context-datum-heap context))))
            (error "environment belongs to another evaluation datum heap"))
        (or heap (context-datum-heap context))))

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
    ;; environments.
    (define-record-type <procedure>
      (make-procedure formals body environment documentation
        syntax-environment)
      consent-procedure?
      (formals procedure-formals)
      (body procedure-body)
      (environment procedure-environment)
      (documentation procedure-documentation)
      (syntax-environment procedure-syntax-environment))

    ;; Primitive procedures are the kernel boundary: each call is budgeted as a
    ;; host callback even when the primitive implements pure R7RS behavior.
    (define-record-type <primitive-procedure>
      (make-primitive-procedure-record
       name
       function
       minimum-arity
       maximum-arity
       documentation)
      consent-primitive-procedure?
      (name primitive-procedure-name)
      (function primitive-procedure-function)
      (minimum-arity primitive-procedure-minimum-arity)
      (maximum-arity primitive-procedure-maximum-arity)
      (documentation
       primitive-procedure-documentation
       set-primitive-procedure-documentation!))

    (define (make-primitive-procedure
             name
             function
             minimum-arity
             maximum-arity
             .
             maybe-documentation)
      "Create a runtime primitive procedure with optional DOCUMENTATION."
      #((parameters
         (name (type symbol)
          (description "Private dispatch name for the primitive."))
         (function (type procedure)
          (description "Host procedure implementing the primitive."))
         (minimum-arity (type exact-integer)
          (description "Minimum number of accepted arguments."))
         (maximum-arity (type (or exact-integer boolean))
          (description "Maximum accepted arguments, or #f for unbounded."))
         (maybe-documentation (type list)
          (description "Optional singleton list of procedure documentation.")))
        (returns (type primitive-procedure)
         (description "Fresh primitive procedure record."))
        (effects allocation))
      (make-primitive-procedure-record
       name
       function
       minimum-arity
       maximum-arity
       (if (null? maybe-documentation)
           #f
           (car maybe-documentation))))

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
                         maximum-value-nodes maximum-source-metadata
                         value-nodes host-callbacks
                         maximum-host-callbacks syntax-environment libraries
                         native-binding-cache source-copies
                         include-paths include-directory file-paths
                         docstring-retention
                         boundary-contract-checking
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
                         command-line
                         interaction-environment
                         base-syntax-installed next-syntax-id
                         exception-handlers dynamic-winds
                         internal-libraries-allowed
                         output-bytes maximum-output-bytes
                         maximum-wall-time-ms wall-clock wall-start
                         exhaustion-reason symbol-table datum-heap
                         interned-symbols maximum-interned-symbols)
      eval-context?
      (steps context-steps set-context-steps!)
      (maximum-steps context-maximum-steps set-context-maximum-steps!)
      (maximum-value-nodes context-maximum-value-nodes
                           set-context-maximum-value-nodes!)
      (maximum-source-metadata context-maximum-source-metadata
                               set-context-maximum-source-metadata!)
      (value-nodes context-value-nodes set-context-value-nodes!)
      ;; Cumulative evaluated `string->symbol' interning operations and the
      ;; run's
      ;; ceiling. Each call charges one unit, bounding how many symbols a run
      ;; can add to the global intern table.
      (interned-symbols context-interned-symbols set-context-interned-symbols!)
      (maximum-interned-symbols context-maximum-interned-symbols
                                set-context-maximum-interned-symbols!)
      (symbol-table context-symbol-table set-context-symbol-table!)
      (datum-heap context-datum-heap set-context-datum-heap!)
      (host-callbacks context-host-callbacks set-context-host-callbacks!)
      (maximum-host-callbacks context-maximum-host-callbacks
                              set-context-maximum-host-callbacks!)
      (event-count context-event-count set-context-event-count!)
      (maximum-events context-maximum-events set-context-maximum-events!)
      (maximum-event-nodes context-maximum-event-nodes)
      (syntax-environment context-syntax-environment
                          set-context-syntax-environment!)
      (libraries context-libraries set-context-libraries!)
      ;; Native binding cells are shared only within one evaluation context.
      ;; Keeping this cache on the context prevents process-history retention
      ;; while preserving location identity across same-context re-exports.
      (native-binding-cache context-native-binding-cache
                            set-context-native-binding-cache!)
      ;; Cached source syntax is copied once per evaluation context. The state
      ;; vector holds a bounded count and runtime-to-canonical provenance map
      ;; without retaining the context globally.
      (source-copies context-source-copies)
      (include-paths context-include-paths)
      (include-directory context-include-directory
                         set-context-include-directory!)
      (file-paths context-file-paths)
      (docstring-retention context-docstring-retention)
      (boundary-contract-checking context-boundary-contract-checking)
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
      (command-line context-command-line)
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
      (internal-libraries-allowed context-internal-libraries-allowed?)
      ;; Cumulative printed-output bytes and the run's output ceiling.
      (output-bytes context-output-bytes set-context-output-bytes!)
      (maximum-output-bytes context-maximum-output-bytes
                            set-context-maximum-output-bytes!)
      ;; Wall-time ceiling in milliseconds (#f leaves it unbounded), the
      ;; injected host clock thunk (() -> integer milliseconds, or #f), and the
      ;; clock baseline captured at the first wall-time check.
      (maximum-wall-time-ms context-maximum-wall-time-ms
                            set-context-maximum-wall-time-ms!)
      (wall-clock context-wall-clock set-context-wall-clock!)
      (wall-start context-wall-start set-context-wall-start!)
      ;; The dimension symbol that exhausted this run's budget, or #f. Set just
      ;; before a budget error raises so the stop receipt names the dimension.
      (exhaustion-reason context-exhaustion-reason
                         set-context-exhaustion-reason!))

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
      #((parameters
         (options (type list)
          (description "Association list of option key/value pairs."))
         (key (type symbol)
          (description "Option key to look up via eq? comparison."))
         (default . "Value to return when KEY is absent from OPTIONS."))
        (returns
         . ("The value associated with KEY, or DEFAULT when KEY is"
            "absent."))
        (effects allocation state-write))
      (let ((cell (runtime-assq key options)))
        (if cell (cdr cell) default)))

    (define (eval-error message . irritants)
      "Raise an evaluator error with the Consent Scheme diagnostic prefix."
      #((parameters
         (message (type string)
          (description "Diagnostic message describing the evaluator error."))
         (irritants (type list)
          (description
            ("Zero or more irritant values attached to the error."))))
        (returns . "Does not return; always raises an error condition.")
        (effects error))
      (apply error
             (string-append "consent eval error: " message)
             irritants))

    (define (budget-error message . irritants)
      "Raise an evaluator budget error with the Consent Scheme diagnostic pref\
ix."
      #((parameters
         (message (type string)
          (description "Diagnostic message describing the budget error."))
         (irritants (type list)
          (description
            ("Zero or more irritant values attached to the error."))))
        (returns .
          ("Does not return; always raises a budget error condition."))
        (effects error))
      (apply error
             (string-append "consent budget error: " message)
             irritants))

    (define (budget-stop! context reason message . irritants)
      "Record REASON as the budget dimension that stopped CONTEXT, then raise.\
"
      "Centralizing the stop-receipt reason lets the comprehensive ledger and"
      "the error condition name which dimension was no longer admissible while\
"
      "the host diagnostic itself stays unchanged and uncatchable."
      (if context
          (set-context-exhaustion-reason! context reason))
      (apply budget-error message irritants))

    (define (normalize-docstring-retention value)
      "Return the normalized docstring retention mode for VALUE."
      (cond
       ((runtime-symbol-eq? value #t) 'full)
       ((runtime-symbol-eq? value #f) 'none)
       ((runtime-memq value '(full simple none)) value)
       (else
        (eval-error
         "docstring-retention must be full, simple, none, or #f"
         value))))

    (define (normalize-boundary-contract-checking value)
      "Return the normalized boundary contract checking mode for VALUE."
      (cond
       ((runtime-symbol-eq? value #t) 'shallow)
       ((or (runtime-symbol-eq? value #f) (runtime-symbol-eq? value 'none)) #f)
       ((runtime-symbol-eq? value 'shallow) 'shallow)
       (else
        (eval-error
         "boundary-contract-checking must be shallow, none, #t, or #f"
         value))))

    (define (normalize-include-directory directory)
      "Normalize include-directory options to a stable prefix form."
      #((parameters
         (directory (type string)
          (description "Include-directory path string to normalize.")))
        (returns (type string)
         (description
          ("The directory as an empty string or a slash-terminated"
            "prefix.")))
        (effects pure))
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
      #((parameters
         (path (type string)
          (description "Path string to test for absoluteness.")))
        (returns (type boolean)
         (description "#t when PATH begins with a slash, #f otherwise."))
        (effects pure))
      (and (> (string-length path) 0)
           (char=? (string-ref path 0) #\/)))

    (define (path-join directory path)
      "Join DIRECTORY and PATH unless PATH is already absolute."
      #((parameters
         (directory (type string)
          (description "Directory prefix to prepend to PATH."))
         (path (type string)
          (description
           ("Path to join onto DIRECTORY, or returned unchanged when"
             "absolute."))))
        (returns (type string)
         (description
           ("The joined path string with a single slash separator.")))
        (effects pure))
      (cond
       ((or (string=? directory "") (path-absolute? path))
        path)
       ((char=? (string-ref directory (- (string-length directory) 1)) #\/)
        (string-append directory path))
       (else
        (string-append directory "/" path))))

    (define (path-split path)
      "Split PATH on slash characters, preserving empty components for absolut\
e"
      "path detection while letting normalization discard redundant separators\
."
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
      "Resolve . and .. path components without consulting the host filesystem\
."
      #((parameters
         (path (type string)
          (description
           ("Path string whose . and .. components are resolved"
             "syntactically."))))
        (returns (type string)
         (description
          ("The normalized path string, preserving leading-slash"
            "absoluteness.")))
        (effects pure))
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
      (let ((entry (and (pair? datum) (runtime-assq field (cdr datum)))))
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
           ((and (pair? (car rest)) (runtime-symbol-eq? (caar rest) name)) (car
             rest))
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
           (runtime-symbol-eq? (car grant) 'capability-grant)
           (runtime-symbol-eq? (capability-field-value grant 'domain) 'file)))

    (define (capability-grant-active? grant)
      "Report whether GRANT currently has active status."
      (let ((status (capability-field-value grant 'status)))
        (or (not status) (runtime-symbol-eq? status 'active))))

    (define (file-capability-operation? grant operation)
      "Report whether GRANT authorizes OPERATION."
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (runtime-symbol-eq? (car operations) operation)
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
      "Report whether FILENAME names a non-local resource outside file grants.\
"
      (string-contains? filename "://"))

    (define (file-capability-effect operation)
      "Return the effect class for a file capability operation."
      (if (runtime-memq operation '(write create delete))
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
                   ((runtime-memq operation '(include include-ci
                     library-source))
                    '(scheme base))
                   ((runtime-symbol-eq? operation 'load) '(scheme load))
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
      #((parameters
         (filename (type string)
          (description
           ("File path requested by the program, relative to the"
             "include directory.")))
         (context (type eval-context)
          (description
           ("Evaluation context holding capability grants and audit"
             "events.")))
         (operation (type symbol)
          (description
           ("File operation symbol being authorized, such as read or"
             "write.")))
         (binding (type (or symbol string))
          (description
            ("Name of the host binding requesting the file capability.")))
         (legacy-paths (type (list-of string))
          (description
           ("Legacy permitted paths folded into the available file"
             "grants."))))
        (returns (type list)
         (description
          ("An authorization alist with path, request, decision,"
            "operation, grant, and handle entries.")))
        (effects state-write error))
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
          (if (or (not match) (runtime-symbol-eq? (car match) 'denied))
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
      #((parameters
         (authorization (type list)
          (description
            ("Authorization alist produced by authorize-file-capability."))))
        (returns (type string)
         (description
           ("The normalized host path string recorded in AUTHORIZATION.")))
        (effects pure))
      (cadr (runtime-assq 'path authorization)))

    (define (audit-file-capability-result!
             context authorization result error?)
      "Record the result of an authorized file capability operation."
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose audit log receives the event.")))
         (authorization (type list)
          (description
            ("Authorization alist identifying the request and decision.")))
         (result . "Result value or error object produced by the operation.")
         (error? (type boolean)
          (description
            ("True when RESULT represents an error rather than success."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (runtime-assq 'request authorization)))
             (list 'decision (cadr (runtime-assq 'decision authorization)))
             (list 'domain 'file)
             (list 'operation (cadr (runtime-assq 'operation authorization)))
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
                          (cadr (runtime-assq 'request authorization))))
              (list 'effect 'environment-mutation))))

    (define (authorize-code-loading authorization context binding)
      "Authorize evaluation of source forms read by a file capability request.\
"
      #((parameters
         (authorization (type list)
          (description
           ("File authorization alist whose path is being loaded as"
             "code.")))
         (context (type eval-context)
          (description
            ("Evaluation context whose audit log receives the events.")))
         (binding (type (or symbol string))
          (description
           ("Name of the host binding requesting the code-loading"
             "capability."))))
        (returns (type list)
         (description
          ("A code-loading authorization alist with path, request,"
            "decision, and operation entries.")))
        (effects state-write))
      (let* ((path (file-authorization-path authorization))
             (request (code-loading-request authorization binding))
             (decision
              (list 'capability-decision
                    (list 'request request)
                    (list 'status 'approved)
                    (list 'domain 'code-loading)
                    (list 'reason
                          "load target is authorized under current evaluation \
context"))))
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
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose audit log receives the event.")))
         (authorization (type list)
          (description
           ("Code-loading authorization alist identifying the request"
             "and decision.")))
         (result . "Result value or error object produced by the load.")
         (error? (type boolean)
          (description
            ("True when RESULT represents an error rather than success."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (runtime-assq 'request authorization)))
             (list 'decision (cadr (runtime-assq 'decision authorization)))
             (list 'domain 'code-loading)
             (list 'operation 'load)
             (list 'result
                   (if error?
                       (list 'error result)
                       (list 'ok result))))))

    (define (clock-capability-grant? grant)
      "Report whether GRANT is a clock-domain capability grant."
      (and (pair? grant)
           (runtime-symbol-eq? (car grant) 'capability-grant)
           (runtime-symbol-eq? (capability-field-value grant 'domain) 'clock)))

    (define (clock-capability-operation? grant operation)
      "Report whether GRANT authorizes clock OPERATION."
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (runtime-symbol-eq? (car operations) operation)
                 (runtime-symbol-eq? (car operations) 'read)
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
         ((runtime-symbol-eq? (capability-field-value (car rest) 'status)
           'revoked)
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
      (let ((entry (runtime-assq 'standard-host-effect
                         (context-policy-actions context))))
        (if entry (cdr entry) 'allow)))

    (define (authorize-clock-policy!
             context request binding operation grant)
      "Require policy approval after a clock grant covers the operation."
      (let ((grant-id (capability-field-value grant 'id)))
        (if (runtime-symbol-eq? (clock-policy-action context) 'allow)
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
           (runtime-symbol-eq? (car grant) 'capability-grant)
           (runtime-symbol-eq? (capability-field-value grant 'domain)
             'process-environment)
           (capability-grant-active? grant)))

    (define (process-environment-granted? context)
      "Report whether CONTEXT carries an active process-environment grant."
      (let loop ((grants (context-capability-grants context)))
        (and (pair? grants)
             (or (process-environment-capability-grant? (car grants))
                 (loop (cdr grants))))))

    (define (authorize-process-environment-capability binding context)
      "Authorize a policy-gated `(scheme process-context)' environment read."
      "Host environment access is denied unless CONTEXT carries an active"
      "process-environment capability grant, so it stays opt-in and revocable"
      "while remaining available to a caller that deliberately grants it."
      "Records the capability decision for the audit trail and raises on"
      "denial."
      #((parameters
         (binding (type string)
          (description
           ("Name of the host binding requesting process-environment"
             "access.")))
         (context (type eval-context)
          (description
           ("Evaluation context whose grants and audit log are"
             "consulted."))))
        (returns (type boolean)
         (description
          ("#t when an active grant authorizes the read; otherwise"
            "raises.")))
        (effects state-write error))
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
      #((parameters
         (binding (type symbol)
          (description "Name of the host binding requesting the clock read."))
         (context (type eval-context)
          (description
           ("Evaluation context whose clock grants and audit log are"
             "consulted."))))
        (returns (type list)
         (description
          ("An authorization alist with request, decision, operation,"
            "and grant entries.")))
        (effects state-write error))
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
          (if (or (not match) (runtime-symbol-eq? (car match) 'denied))
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
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose audit log receives the event.")))
         (authorization (type list)
          (description
           ("Clock authorization alist identifying the request and"
             "decision.")))
         (result . "Result value or error object produced by the clock read.")
         (error? (type boolean)
          (description
            ("True when RESULT represents an error rather than success."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (runtime-assq 'request authorization)))
             (list 'decision (cadr (runtime-assq 'decision authorization)))
             (list 'domain 'clock)
             (list 'operation (cadr (runtime-assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error result)
                       (list 'ok result))))))

    (define (process-name-string value)
      "Return VALUE as a string name when it names a host process resource."
      (cond
       ((runtime-symbol? value) (runtime-symbol-name value))
       ((string? value) value)
       (else #f)))

    (define (process-member-equal? value values)
      "Return #t when VALUE is in VALUES using equal?."
      (cond
       ((null? values) #f)
       ((equal? value (car values)) #t)
       (else (process-member-equal? value (cdr values)))))

    (define (process-resource-fields resource)
      "Return RESOURCE's field alist, accepting either a plain field list or a\
"
      "`(resource ...)` datum."
      (if (and (pair? resource) (runtime-symbol-eq? (car resource) 'resource))
          (cdr resource)
          resource))

    (define (process-resource-field-values resource field)
      "Return all values for RESOURCE FIELD."
      (let ((entry (runtime-assq field (process-resource-fields resource))))
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
      #((parameters
         (operation (type symbol)
          (description
           ("Process operation symbol to classify, such as spawn or"
             "status."))))
        (returns (type symbol)
         (description
          ("The symbol process-control for mutating operations, else"
            "read-only-observation.")))
        (effects pure))
      (if (runtime-memq operation '(spawn input interrupt terminate))
          'process-control
          'read-only-observation))

    (define (process-capability-policy-category operation)
      "Return the policy category for a process capability operation."
      #((parameters
         (operation (type symbol)
          (description
           ("Process operation symbol whose policy category is"
             "requested."))))
        (returns (type symbol)
         (description
          ("The symbol command-process for process-control effects,"
            "else emacs-read-only.")))
        (effects pure))
      (if (runtime-symbol-eq? (process-capability-effect operation)
        'process-control)
          'command-process
          'emacs-read-only))

    (define (process-capability-grant? grant)
      "Report whether GRANT is a process-domain grant."
      (and (pair? grant)
           (runtime-symbol-eq? (car grant) 'capability-grant)
           (runtime-symbol-eq? (capability-field-value grant 'domain)
             'process)))

    (define (process-capability-operation? grant operation)
      "Report whether GRANT authorizes process OPERATION."
      (let loop ((operations (capability-field-values grant 'operations)))
        (and (pair? operations)
             (or (runtime-symbol-eq? (car operations) operation)
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
      "Return a matching process grant for RESOURCE and OPERATION, or a denial \
tuple."
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         ((not (process-capability-operation? (car rest) operation))
          (loop (cdr rest) denied))
         ((runtime-symbol-eq? (capability-field-value (car rest) 'status)
           'revoked)
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
      #((parameters
         (library (type (list-of (or symbol exact-integer)))
          (description
            ("Library specifier naming the requesting host library.")))
         (binding (type (or symbol string))
          (description "Name of the host binding making the request."))
         (operation (type symbol)
          (description "Process operation symbol being requested."))
         (resource (type list)
          (description
           ("Process resource descriptor whose fields are redacted into"
             "the request."))))
        (returns
         . ("A capability-request datum describing the process"
            "operation."))
        (effects pure))
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
      "Record DENIAL for process REQUEST and raise a portable evaluator error.\
"
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
      (let ((entry (runtime-assq category (context-policy-actions context))))
        (cond
         (entry (cdr entry))
         ((runtime-symbol-eq? category 'emacs-read-only) 'allow)
         (else 'deny))))

    (define (authorize-process-policy!
             context request binding operation resource grant)
      "Require host policy approval for a process capability request."
      (let* ((category (process-capability-policy-category operation))
             (action (process-policy-action context category))
             (grant-id (capability-field-value grant 'id)))
        (if (runtime-symbol-eq? action 'allow)
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
      "Authorize a host adapter process request against the shared process"
      "capability vocabulary.  This does not start or observe a real process;"
      "adapters call it before touching host process APIs."
      #((parameters
         (library (type (list-of (or symbol exact-integer)))
          (description
            ("Library specifier naming the requesting host library.")))
         (binding (type (or symbol string))
          (description "Name of the host binding making the request."))
         (context (type eval-context)
          (description
           ("Evaluation context whose process grants and audit log are"
             "consulted.")))
         (operation (type symbol)
          (description "Process operation symbol being authorized."))
         (resource (type list)
          (description
           ("Process resource descriptor naming command, arguments, and"
             "environment.")))
         (command-allow-list (type list)
          (description "List of commands permitted for spawn operations.")))
        (returns (type list)
         (description
          ("An authorization alist with request, decision, operation,"
            "and grant entries.")))
        (effects state-write error))
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
        (if (and (runtime-symbol-eq? operation 'spawn)
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
          (if (or (not match) (runtime-symbol-eq? (car match) 'denied))
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
      #((parameters
         (id (type (or symbol string))
          (description "Identifier assigned to the process job handle."))
         (resource (type list)
          (description
           ("Process resource descriptor whose command and arguments"
             "are redacted in.")))
         (grant (type (or symbol string))
          (description "Grant identifier backing the handle."))
         (status (type symbol)
          (description
            ("Status symbol describing the handle's lifecycle state."))))
        (returns (type list)
         (description "A handle datum describing the process job."))
        (effects pure))
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
      #((parameters
         (id (type (or symbol string))
          (description "Identifier assigned to the port capability."))
         (kind (type symbol)
          (description "Port kind symbol, such as input or output."))
         (process-handle (type list)
          (description
           ("Handle of the backing process the port is attached to.")))
         (operations (type (list-of symbol))
          (description "List of operations the port permits."))
         (grant (type (or symbol string))
          (description "Grant identifier backing the port capability."))
         (limits (type list)
          (description "List of limit entries constraining the port."))
         (status (type symbol)
          (description
            ("Status symbol describing the port's lifecycle state."))))
        (returns (type list)
         (description
          ("A port-capability datum describing the process-backed"
            "port.")))
        (effects pure))
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
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose audit log receives the event.")))
         (authorization (type list)
          (description
           ("Process authorization alist identifying the request and"
             "decision.")))
         (result
          . ("Result value or error object produced by the operation,"
             "redacted on record."))
         (error? (type boolean)
          (description
            ("True when RESULT represents an error rather than success."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (runtime-assq 'request authorization)))
             (list 'decision (cadr (runtime-assq 'decision authorization)))
             (list 'domain 'process)
             (list 'operation (cadr (runtime-assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error (redact result 'local-only))
                       (list 'ok (redact result 'local-only)))))))

    (define (network-resource-fields resource)
      "Return RESOURCE's field alist, accepting either a plain field list or a\
"
      "`(resource ...)` datum."
      (if (and (pair? resource) (runtime-symbol-eq? (car resource) 'resource))
          (cdr resource)
          resource))

    (define (network-resource-field-values resource field)
      "Return all values for RESOURCE FIELD."
      (let ((entry (runtime-assq field (network-resource-fields resource))))
        (if entry (cdr entry) '())))

    (define (network-resource-value resource field)
      "Return RESOURCE FIELD's first value, or #f."
      (let ((values (network-resource-field-values resource field)))
        (if (pair? values) (car values) #f)))

    (define (network-resource-values resource field)
      "Return RESOURCE FIELD's values, flattening single nested list fields."
      (capability-flatten-values
       (network-resource-field-values resource field)))

    (define (host-number->consent-number number)
      "Convert host NUMBER to the canonical Consent numeric representation."
      (cond
       ((and (real? number) (exact? number) (integer? number))
        (consent-make-canonical-integer number))
       ((and (real? number) (exact? number))
        (consent-make-canonical-rational
         (numerator number)
         (denominator number)))
       ((real? number)
        (consent-make-canonical-decimal number))
       (else
        ;; Numeric canonicalization needs no syntax provenance. Avoid making
        ;; every host-number conversion a process-lifetime reader metadata
        ;; root through the private host-syntax entry point.
        (consent-read
         (number->string number)
         '((source-metadata . #f))))))

    (define (consent-host-datum->consent-datum datum . maybe-wrap-procedure)
      "Convert host-owned DATUM into the Consent runtime representation."
      "Numbers become canonical Consent numbers, the host eof object becomes"
      "the Consent eof record, pairs and vectors are rebuilt copy-on-write"
      "while preserving attached reader source metadata, and an optional"
      "procedure wrapper can translate host callables when a boundary needs"
      "that bridge."
      #((parameters
         (datum (type object)
          (description
           ("Host datum or scalar crossing into the Consent runtime"
             "representation.")))
         (maybe-wrap-procedure (type list)
          (description
           ("Optional single procedure that rewrites host procedures before"
             "they enter Consent data; omitted leaves them unchanged."))))
        (returns (type object)
         (description
          ("DATUM rewritten into Consent runtime data, preserving source"
            "metadata on rebuilt pairs and vectors.")))
        (effects pure allocation))
      (let ((wrap-procedure
             (if (null? maybe-wrap-procedure)
                 (lambda (value) value)
                 (car maybe-wrap-procedure))))
        (define (host-conversion-compound? value)
          "Report whether VALUE participates in host graph topology."
          (or (pair? value) (vector? value)))
        (define (convert-leaf value)
          "Convert one non-compound host VALUE."
          (cond
           ((or (consent-number? value)
                (consent-character? value)
                (consent-eof-object? value))
            value)
           ((number? value)
            (host-number->consent-number value))
           ((eof-object? value)
            consent-eof-object)
           ((char? value)
            (consent-host-character->character value))
           ((procedure? value)
            (wrap-procedure value))
           (else value)))
        ;; Scalar boundary values dominate this helper's callers. Avoid the
        ;; graph registry and worklist unless DATUM can contain graph edges.
        (if (not (host-conversion-compound? datum))
            (convert-leaf datum)
            (let ((nodes-by-source #f)
                  (all-nodes '())
                  (locally-changed '()))
              (define (conversion-node-ref source)
                "Return SOURCE's conversion node, or #f before/if absent."
                "Node slots are source, pair-kind?, edge payloads, compound"
                "flags, reverse parents, changed?, and output. Reverse parents"
                "let one changed leaf mark every ancestor in O(V+E)."
                (and
                 nodes-by-source
                 (consent-identity-map-ref nodes-by-source source #f)))
              (define (make-conversion-node source)
                "Create and memoize one host compound conversion node."
                (if (not nodes-by-source)
                    (set! nodes-by-source (consent-make-identity-map)))
                (let* ((pair-kind? (pair? source))
                       (length (if pair-kind? 2 (vector-length source)))
                       (node
                        (vector source
                                pair-kind?
                                (make-vector length #f)
                                (make-vector length #f)
                                '()
                                #f
                                #f)))
                  (consent-identity-map-set!
                   nodes-by-source source node)
                  (set! all-nodes (cons node all-nodes))
                  node))
              (define (mark-conversion-node-changed! node)
                "Mark NODE locally changed exactly once."
                (if (not (vector-ref node 5))
                    (begin
                      (vector-set! node 5 #t)
                      (set! locally-changed
                            (cons node locally-changed)))))
              (define (conversion-source-child source pair-kind? index)
                "Return SOURCE's child at INDEX."
                (if pair-kind?
                    (if (= index 0) (car source) (cdr source))
                    (vector-ref source index)))
              (define (discover-conversion-graph! root)
                "Discover ROOT depth-first with an explicit worklist."
                (let loop ((work (list (cons root 0))))
                  (if (not (null? work))
                      (let* ((task (car work))
                             (node (car task))
                             (index (cdr task))
                             (source (vector-ref node 0))
                             (pair-kind? (vector-ref node 1))
                             (edges (vector-ref node 2))
                             (length (vector-length edges))
                             (rest (cdr work)))
                        (if (= index length)
                            (loop rest)
                            (let* ((next-index (+ index 1))
                                   (next-work
                                    (if (< next-index length)
                                        (cons
                                         (cons node next-index)
                                         rest)
                                        rest))
                                   (child
                                    (conversion-source-child
                                     source pair-kind? index)))
                              (if (host-conversion-compound? child)
                                  (let ((child-node
                                         (conversion-node-ref child)))
                                    (if child-node
                                        (begin
                                          (vector-set! edges index child-node)
                                          (vector-set!
                                           (vector-ref node 3) index #t)
                                          (vector-set!
                                           child-node
                                           4
                                           (cons
                                            node
                                            (vector-ref child-node 4)))
                                          (loop next-work))
                                        (let ((created
                                               (make-conversion-node child)))
                                          (vector-set! edges index created)
                                          (vector-set!
                                           (vector-ref node 3) index #t)
                                          (vector-set!
                                           created
                                           4
                                           (cons node
                                                 (vector-ref created 4)))
                                          (loop
                                           (cons
                                            (cons created 0)
                                            next-work)))))
                                  (let ((converted (convert-leaf child)))
                                    (vector-set! edges index converted)
                                    (if (not
                                         (runtime-symbol-eq?
                                          converted child))
                                        (mark-conversion-node-changed! node))
                                    (loop next-work)))))))))
              (define (propagate-conversion-changes!)
                "Mark every compound ancestor of a changed node."
                (let loop ((work locally-changed))
                  (if (not (null? work))
                      (let parent-loop
                          ((parents (vector-ref (car work) 4))
                           (next (cdr work)))
                        (if (null? parents)
                            (loop next)
                            (let ((parent (car parents)))
                              (if (vector-ref parent 5)
                                  (parent-loop (cdr parents) next)
                                  (begin
                                    (vector-set! parent 5 #t)
                                    (parent-loop
                                     (cdr parents)
                                     (cons parent next))))))))))
              (define (allocate-conversion-outputs!)
                "Allocate placeholders only for compounds that changed."
                (let loop ((rest all-nodes))
                  (if (not (null? rest))
                      (let* ((node (car rest))
                             (source (vector-ref node 0))
                             (output
                              (if (vector-ref node 5)
                                  (if (vector-ref node 1)
                                      (cons #f #f)
                                      (make-vector
                                       (vector-length (vector-ref node 2))
                                       #f))
                                  source)))
                        (vector-set! node 6 output)
                        (if (vector-ref node 5)
                            (consent-copy-datum-source! output source))
                        (loop (cdr rest))))))
              (define (conversion-edge-value node index)
                "Return NODE's converted edge at INDEX."
                (let ((payload (vector-ref (vector-ref node 2) index)))
                  (if (vector-ref (vector-ref node 3) index)
                      (vector-ref payload 6)
                      payload)))
              (define (fill-conversion-outputs!)
                "Fill every changed placeholder from converted edge values."
                (let loop ((rest all-nodes))
                  (if (not (null? rest))
                      (let ((node (car rest)))
                        (if (vector-ref node 5)
                            (let ((output (vector-ref node 6)))
                              (if (vector-ref node 1)
                                  (begin
                                    (set-car!
                                     output
                                     (conversion-edge-value node 0))
                                    (set-cdr!
                                     output
                                     (conversion-edge-value node 1)))
                                  (let fill
                                      ((index 0)
                                       (length
                                        (vector-length
                                         (vector-ref node 2))))
                                    (if (< index length)
                                        (begin
                                          (vector-set!
                                           output
                                           index
                                           (conversion-edge-value node index))
                                          (fill (+ index 1) length)))))))
                        (loop (cdr rest))))))
              (let ((root (make-conversion-node datum)))
                (discover-conversion-graph! root)
                (propagate-conversion-changes!)
                (allocate-conversion-outputs!)
                (fill-conversion-outputs!)
                (vector-ref root 6))))))

    (define (network-public-datum datum)
      "Convert host-owned network metadata to Consent data before publication.\
"
      (consent-host-datum->consent-datum datum))

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
      #((parameters
         (operation (type symbol)
          (description
           ("Network operation symbol to classify, such as stream or"
             "request."))))
        (returns (type symbol)
         (description
          ("The symbol network-stream for stream operations, else"
            "network-egress.")))
        (effects pure))
      (if (runtime-symbol-eq? operation 'stream)
          'network-stream
          'network-egress))

    (define (network-capability-grant? grant)
      "Report whether GRANT is a network-domain grant."
      (and (pair? grant)
           (runtime-symbol-eq? (car grant) 'capability-grant)
           (runtime-symbol-eq? (capability-field-value grant 'domain)
             'network)))

    (define (network-capability-operation? grant operation)
      "Report whether GRANT authorizes network OPERATION."
      (let loop ((operations
                  (capability-flatten-values
                   (capability-field-values grant 'operations))))
        (and (pair? operations)
             (or (runtime-symbol-eq? (car operations) operation)
                 (runtime-symbol-eq? (car operations) 'all)
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
      "Return VALUE's host number payload for capability scope comparisons."
      "Canonical number records arrive in grant and resource datum positions"
      "when requests cross the native import boundary; comparing payloads"
      "makes record and host forms match the same way on every posture."
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
      "Return a matching network grant for RESOURCE and OPERATION, or a denial \
tuple."
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         ((not (network-capability-operation? (car rest) operation))
          (loop (cdr rest) denied))
         ((runtime-symbol-eq? (capability-field-value (car rest) 'status)
           'revoked)
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
      #((parameters
         (library (type (list-of (or symbol exact-integer)))
          (description
            ("Library specifier naming the requesting host library.")))
         (binding (type (or symbol string))
          (description "Name of the host binding making the request."))
         (operation (type symbol)
          (description "Network operation symbol being requested."))
         (resource (type list)
          (description
           ("Network resource descriptor whose fields are redacted into"
             "the request."))))
        (returns
         . ("A capability-request datum describing the network"
            "operation."))
        (effects pure))
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
      "Record DENIAL for network REQUEST and raise a portable evaluator error.\
"
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
      (let ((entry (runtime-assq 'network-access (context-policy-actions
        context))))
        (if entry (cdr entry) 'deny)))

    (define (authorize-network-policy!
             context request binding operation resource grant)
      "Require host policy approval for a network capability request."
      (let ((action (network-policy-action context))
            (grant-id (capability-field-value grant 'id)))
        (if (runtime-symbol-eq? action 'allow)
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
      "Authorize a host adapter network request against the shared network"
      "capability vocabulary. This does not perform transport."
      #((parameters
         (library (type (list-of (or symbol exact-integer)))
          (description
            ("Library specifier naming the requesting host library.")))
         (binding (type (or symbol string))
          (description "Name of the host binding making the request."))
         (context (type eval-context)
          (description
           ("Evaluation context whose network grants and audit log are"
             "consulted.")))
         (operation (type symbol)
          (description "Network operation symbol being authorized."))
         (resource (type list)
          (description
           ("Network resource descriptor naming scheme, host, port, and"
             "method."))))
        (returns (type list)
         (description
          ("An authorization alist with request, decision, operation,"
            "and grant entries.")))
        (effects state-write error))
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
          (if (or (not match) (runtime-symbol-eq? (car match) 'denied))
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
      #((parameters
         (id (type (or symbol string))
          (description "Identifier assigned to the network stream handle."))
         (request (type list)
          (description
            ("Capability request datum the handle was authorized for.")))
         (url (type (or string list))
          (description "URL the network stream is connected to."))
         (grant (type (or symbol string))
          (description "Grant identifier backing the handle."))
         (status (type symbol)
          (description
            ("Status symbol describing the handle's lifecycle state."))))
        (returns (type list)
         (description "A handle datum describing the network stream."))
        (effects pure))
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
      #((parameters
         (id (type (or symbol string))
          (description "Identifier assigned to the port capability."))
         (kind (type symbol)
          (description "Port kind symbol, such as input or output."))
         (stream-handle (type list)
          (description
           ("Handle of the backing network stream the port is attached"
             "to.")))
         (operations (type (list-of symbol))
          (description "List of operations the port permits."))
         (grant (type (or symbol string))
          (description "Grant identifier backing the port capability."))
         (limits (type list)
          (description "List of limit entries constraining the port."))
         (status (type symbol)
          (description
            ("Status symbol describing the port's lifecycle state."))))
        (returns (type list)
         (description
          ("A port-capability datum describing the network-backed"
            "port.")))
        (effects pure))
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
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose audit log receives the event.")))
         (authorization (type list)
          (description
           ("Network authorization alist identifying the request and"
             "decision.")))
         (result
          . ("Result value or error object produced by the operation,"
             "redacted on record."))
         (error? (type boolean)
          (description
            ("True when RESULT represents an error rather than success."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (record-audit-event!
       context
       'capability-audit
       (list (list 'request (cadr (runtime-assq 'request authorization)))
             (list 'decision (cadr (runtime-assq 'decision authorization)))
             (list 'domain 'network)
             (list 'operation (cadr (runtime-assq 'operation authorization)))
             (list 'result
                   (if error?
                       (list 'error
                             (network-redacted-public-datum result))
                       (list 'ok
                             (network-redacted-public-datum result)))))))

    (define (normalize-include-paths paths directory)
      "Resolve relative include paths against the active include directory."
      #((parameters
         (paths (type (list-of string))
          (description "List of include path strings to resolve."))
         (directory (type string)
          (description
            ("Include directory prefix to join relative paths against."))))
        (returns (type (list-of string))
         (description "A list of normalized path strings."))
        (effects pure))
      (map (lambda (path)
             (path-normalize (path-join directory path)))
           paths))

    (define (option-count options key default)
      "Return numeric option KEY as a host count."
      "A canonical number record is unwrapped when present, but plain host"
      "numbers are accepted too so native and source-hosted callers share"
      "the same Scheme numeric surface."
      (let ((value (option-ref options key default)))
        (if (consent-number? value)
            (consent-number-value value)
            value)))

    (define (new-eval-context options)
      "Create a fresh evaluation context from user option overrides."
      #((parameters
         (options (type list)
          (description
           ("Association list of user option overrides controlling"
             "budgets, paths, capabilities, and context fields."))))
        (returns
         . ("A freshly initialized eval-context record seeded from"
            "OPTIONS and defaults."))
        (effects pure))
      (let ((include-directory
             (normalize-include-directory
              (option-ref options 'include-directory "."))))
      (make-eval-context
       0
       (if (runtime-assq 'max-steps options)
           (option-count options 'max-steps consent-default-maximum-steps)
           (option-count options
                         'max-non-tail-steps
                         consent-default-maximum-steps))
       (option-count options
                     'max-value-nodes
                     consent-default-maximum-value-nodes)
       (option-count options
                     'max-source-metadata
                     consent-default-maximum-source-metadata)
       0
       0
       (option-count options
                     'max-host-callbacks
                     consent-default-maximum-host-callbacks)
       (make-syntax-environment '() #f '())
       '()
       #f
       (vector 0 (make-context-source-copy-map))
       (normalize-include-paths
        (option-ref options 'include-paths '())
        include-directory)
       include-directory
       (normalize-include-paths
        (option-ref options 'file-paths '())
        include-directory)
       (normalize-docstring-retention
        (option-ref options 'docstring-retention 'full))
       (normalize-boundary-contract-checking
        (option-ref options 'boundary-contract-checking #f))
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
       (option-ref options 'command-line #f)
       #f
       #f
       0
       '()
       '()
       (option-ref options 'internal-libraries-allowed #f)
       0
       (option-count options
                     'max-output-bytes
                     consent-default-maximum-output-bytes)
       (option-count options
                     'max-wall-time-ms
                     consent-default-maximum-wall-time-ms)
       (option-ref options 'wall-clock #f)
       #f
       #f
       (option-ref options 'symbol-table consent-default-symbol-table)
       (option-ref options 'datum-heap (consent-make-datum-heap))
       0
       (option-count options
                     'max-interned-symbols
                     consent-default-maximum-interned-symbols))))

    (define (context-source-copy-count context)
      "Return CONTEXT's retained host-side source-note count."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose source-copy overlay is"
             "inspected."))))
        (returns (type exact-integer)
         (description
          "Number of host source-note entries retained by CONTEXT."))
        (effects state-read))
      (vector-ref (context-source-copies context) 0))

    (define (make-runtime-identity-map)
      "Return an empty lazy owned/host hybrid runtime identity map."
      (vector #f #f))

    (define (runtime-identity-map-ref map key default)
      "Return identity KEY's value in MAP, or DEFAULT."
      (let* ((owned? (consent-datum-object? key))
             (backend (vector-ref map (if owned? 0 1))))
        (if (not backend)
            default
            (if owned?
                (consent-datum-object-map-ref backend key default)
                (consent-identity-map-ref backend key default)))))

    (define (runtime-identity-map-set! map key value)
      "Associate identity KEY with VALUE in MAP and return VALUE."
      (let* ((owned? (consent-datum-object? key))
             (index (if owned? 0 1))
             (backend
              (or
               (vector-ref map index)
               (let ((created
                      (if owned?
                          (consent-make-datum-object-map)
                          (consent-make-identity-map))))
                 (vector-set! map index created)
                 created))))
        (if owned?
            (consent-datum-object-map-set! backend key value)
            (consent-identity-map-set! backend key value)))
      value)

    (define (runtime-identity-map-release! map)
      "Release MAP's call-scoped owned-object backend when allocated."
      (let ((owned (vector-ref map 0)))
        (if owned (consent-datum-object-map-release! owned)))
      map)

    (define (make-context-source-copy-map)
      "Return a lazy box for the host-only source-copy identity map."
      (vector #f))

    (define (context-source-copy-direct-owner? value)
      "Report whether VALUE owns its current provenance slot directly."
      (or (consent-datum-object? value)
          (consent-number? value)
          (and (consent-record? value)
               (not (consent-symbol? value)))
          (consent-record-type? value)))

    (define (context-source-copy-map-ref map key default)
      "Return identity KEY's value in source-copy MAP, or DEFAULT."
      (if (context-source-copy-direct-owner? key)
          (or (consent-datum-source-metadata key) default)
          (let ((backend (vector-ref map 0)))
            (if backend
                (consent-identity-map-ref backend key default)
                default))))

    (define (context-source-copy-map-set! map key value)
      "Associate identity KEY with VALUE in source-copy MAP."
      (if (context-source-copy-direct-owner? key)
          (consent-datum-source-set! key value)
          (let ((backend
                 (or (vector-ref map 0)
                     (let ((created (consent-make-identity-map)))
                       (vector-set! map 0 created)
                       created))))
            (consent-identity-map-set! backend key value))))

    (define (context-source-copy-source-ref context value)
      "Return materialized CONTEXT-local source metadata for copied VALUE."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose source-copy overlay is"
             "inspected.")))
         (value (type any)
          (description "Potential context-owned source copy.")))
        (returns (type (or source-metadata boolean))
         (description
          ("Source metadata for VALUE's canonical source, or #f when"
            "VALUE is not a context-owned source copy.")))
        (effects allocation state-read))
      (let ((metadata (context-source-copy-metadata-ref context value)))
        (if metadata
            (consent-source-metadata->record metadata)
            #f)))

    (define (context-source-copy-metadata-ref context value)
      "Return VALUE's copied source metadata in CONTEXT, or #f."
      (context-source-copy-map-ref
       (vector-ref (context-source-copies context) 1)
       value
       #f))

    (define (context-source-copy-attachable? value)
      "Report whether VALUE has stable identity for local provenance."
      (or (consent-datum-object? value)
          (pair? value)
          (vector? value)
          (string? value)
          (bytevector? value)
          (consent-number? value)
          (and (consent-record? value)
               (not (consent-symbol? value)))
          (consent-record-type? value)))

    (define (context-source-copy-metadata-set! context value metadata)
      "Record immutable source METADATA for VALUE in CONTEXT."
      "Only host identities retained in the provenance side table consume"
      "the source-metadata ceiling. Direct owners carry their note in the"
      "object and are bounded by ordinary value allocation and reader work."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose source-copy overlay is"
             "extended.")))
         (value (type any)
          (description "Context-owned copy to associate with METADATA."))
         (metadata (type (or source-metadata boolean))
          (description
           ("Opaque immutable source metadata, or #f when no note is"
             "attached."))))
        (returns (type any)
         (description "The original VALUE, unchanged."))
        (effects state-write error))
      ;; A missing note is not an overlay entry. This keeps graph-copy hooks
      ;; for unannotated values from consuming budget or creating ambiguous
      ;; #f-valued map entries.
      (if metadata
          (let* ((state (context-source-copies context))
                 (map (vector-ref state 1))
                 (direct-owner?
                  (context-source-copy-direct-owner? value))
                 (existing
                  (context-source-copy-map-ref map value #f)))
            ;; The observable contract exposes only the current immutable
            ;; note. Direct-owner fields retain no context entry, and replacing
            ;; a host entry must not retain history or consume another unit.
            (if (and (not direct-owner?) (not existing))
                (let* ((count (vector-ref state 0))
                       (next-count (+ count 1))
                       (limit (context-maximum-source-metadata context)))
                  (if (> next-count limit)
                      (budget-stop!
                       context
                       'source-metadata
                       "source copy count exceeds maximum source metadata"
                       next-count
                       limit))
                  (vector-set! state 0 next-count)))
            (context-source-copy-map-set! map value metadata)))
      value)

    (define (context-source-copy-set! context value source)
      "Record VALUE as CONTEXT's copy of canonical SOURCE."
      "Only SOURCE's immutable metadata enters the overlay; the canonical"
      "container itself does not become a context-lifetime retention root."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose source-copy overlay is"
             "extended.")))
         (value (type any)
          (description "Context-owned copy to associate with SOURCE."))
         (source (type any)
          (description "Canonical source datum represented by VALUE.")))
        (returns (type any)
         (description "The original VALUE, unchanged."))
        (effects state-read state-write error))
      (context-source-copy-metadata-set!
       context
       value
       (or (context-source-copy-metadata-ref context source)
           (consent-datum-source-metadata source))))

    (define (context-source-copy-set-fresh! context value source)
      "Record fresh VALUE as CONTEXT's copy of canonical SOURCE."
      "This source-realization boundary requires a newly allocated VALUE and"
      "a canonical cached SOURCE. It therefore reads SOURCE's raw immutable"
      "note directly and counts VALUE once without probing either identity in"
      "the context overlay. General callers use context-source-copy-set!."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose source-copy overlay is"
             "extended.")))
         (value (type any)
          (description "Fresh context-owned copy of SOURCE."))
         (source (type any)
          (description "Canonical cached source datum represented by VALUE.")))
        (returns (type any)
         (description "The original VALUE, unchanged."))
        (effects state-read state-write error))
      (let ((metadata (consent-datum-source-metadata source)))
        (if metadata
            (let* ((state (context-source-copies context))
                   (map (vector-ref state 1))
                   (direct-owner?
                    (context-source-copy-direct-owner? value)))
              ;; Source-library shells are host compounds today. Preserve the
              ;; direct-owner rule so this boundary stays sound if their
              ;; representation changes: direct slots consume no side-table
              ;; budget, while every fresh host identity consumes one unit.
              (if (not direct-owner?)
                  (let* ((count (vector-ref state 0))
                         (next-count (+ count 1))
                         (limit (context-maximum-source-metadata context)))
                    (if (> next-count limit)
                        (budget-stop!
                         context
                         'source-metadata
                         "source copy count exceeds maximum source metadata"
                         next-count
                         limit))
                    (vector-set! state 0 next-count)))
              (context-source-copy-map-set! map value metadata))))
      value)

    (define (context-copy-datum-source!
             context target source . maybe-overwrite)
      "Copy SOURCE provenance to TARGET in CONTEXT when locally owned."
      "Global reader metadata remains the fallback for directly parsed datums."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose source-copy overlay is"
             "consulted and possibly extended.")))
         (target (type any)
          (description "Datum that receives SOURCE provenance."))
         (source (type any)
          (description "Datum whose provenance is copied to TARGET."))
         (maybe-overwrite (type list)
          (description
           ("Optional flag allowing existing TARGET provenance to be"
             "replaced."))))
        (returns (type any)
         (description "The original TARGET, unchanged."))
        (effects state-read state-write error))
      (let ((metadata
             (or (context-source-copy-metadata-ref context source)
                 (consent-datum-source-metadata source)))
            (overwrite?
             (and (pair? maybe-overwrite) (car maybe-overwrite))))
        (if (and metadata (context-source-copy-attachable? target))
            (if (or overwrite?
                    (and
                     (not (context-source-copy-metadata-ref context target))
                     (not (consent-datum-source-metadata target))))
                (if (context-source-copy-direct-owner? target)
                    ;; Direct provenance follows the published value beyond
                    ;; this evaluation context. The source attachment was
                    ;; already budgeted when the parser created it.
                    (consent-datum-source-set! target metadata)
                    (context-source-copy-metadata-set!
                     context target metadata)))
            (apply
             consent-copy-datum-source!
             target
             source
             maybe-overwrite)))
      target)

    (define (context-reader-options context)
      "Return reader options derived from CONTEXT's resource ceilings."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose reader-facing resource ceilings"
             "are exported."))))
        (returns (type list)
         (description
          ("Association list of reader options derived from CONTEXT.")))
        (effects state-read))
      (list (cons 'max-source-metadata
                  (context-maximum-source-metadata context))
            (cons 'symbol-table (context-symbol-table context))
            (cons 'datum-heap (context-datum-heap context))
            ;; Private syntax provenance belongs to this evaluation context,
            ;; not the reader's process-global compatibility table. The reader
            ;; invokes this sink once per parsed identity-bearing node.
            (cons 'source-metadata-sink
                  (lambda (value metadata)
                    (context-source-copy-metadata-set!
                     context value metadata)))))

    (define (record-audit-event! context event fields)
      "Record a Scheme-readable audit EVENT with FIELDS in CONTEXT."
      #((parameters
         (context (type list)
          (description
            ("Evaluation context whose audit-event list is extended.")))
         (event (type symbol)
          (description "Symbol naming the audit event kind."))
         (fields (type list)
          (description "List of field entries attached to the event.")))
        (returns . "The newly constructed audit-entry datum.")
        (effects state-write))
      (let ((entry (cons 'audit-entry
                         (cons (list 'event event) fields))))
        (set-context-audit-events!
         context
         (cons entry (context-audit-events context)))
        entry))

    (define (record-context-event! context event)
      "Record an ordered event-channel EVENT after enforcing event budgets."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose event count and audit-event list"
             "are updated.")))
         (event
          . ("Event datum to record, sized against the event-node"
             "budget.")))
        (returns . "The recorded EVENT datum.")
        (effects state-write error))
      (let ((node-count (value-node-count event '())))
        (if (> node-count (context-maximum-event-nodes context))
            (budget-stop! context 'event-nodes
                          "event node budget exceeded"
                          node-count
                          (context-maximum-event-nodes context))))
      (if (>= (context-event-count context)
              (context-maximum-events context))
          (budget-stop! context 'events
                        "event count budget exceeded"
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
      "Each evaluation step also re-checks the wall-time budget so an opted-in\
"
      "wall-clock limit interrupts even a tight loop that allocates nothing."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose step counter is incremented and"
             "checked."))))
        (returns (type any)
         (description
          ("The unspecified value, after possibly raising on budget"
            "exhaustion.")))
        (effects state-write error))
      (set-context-steps! context (+ (context-steps context) 1))
      (if (> (context-steps context) (context-maximum-steps context))
          (budget-stop! context 'steps
                        "evaluation step budget exceeded"
                        (context-maximum-steps context)))
      (check-wall-time! context))

    (define (check-wall-time! context)
      "Enforce the wall-time budget when a limit and a host clock are set."
      "A run opts in by configuring `max-wall-time-ms' and a `wall-clock'"
      "thunk; otherwise no clock is read and evaluation stays deterministic."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context holding the wall-time limit, clock"
             "thunk, and start time."))))
        (returns
         . ("The unspecified value; raises when elapsed wall time"
            "exceeds the limit."))
        (effects state-read state-write error))
      (let ((limit (context-maximum-wall-time-ms context))
            (clock (context-wall-clock context)))
        (if (and limit clock)
            (let ((now (clock)))
              (if (not (context-wall-start context))
                  (set-context-wall-start! context now))
              (let ((elapsed (- now (context-wall-start context))))
                (if (> elapsed limit)
                    (budget-stop! context 'wall-time
                                  "wall-time budget exceeded"
                                  elapsed
                                  limit)))))))

    (define (note-host-callback! context primitive)
      "Charge one primitive callback against the host-callback budget."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose host-callback counter is"
             "incremented and checked.")))
         (primitive (type procedure)
          (description
           ("Primitive procedure named in the diagnostic when the"
             "budget is exceeded."))))
        (returns
         . ("The unspecified value, after possibly raising on budget"
            "exhaustion."))
        (effects state-write error))
      (set-context-host-callbacks!
       context
       (+ (context-host-callbacks context) 1))
      (if (> (context-host-callbacks context)
             (context-maximum-host-callbacks context))
          (budget-stop! context 'host-callbacks
                        "host callback budget exceeded"
                        (primitive-procedure-name primitive))))

    (define (note-interned-symbol! context)
      "Charge one evaluated symbol-interning operation against the symbol budg\
et."
      "Called once per evaluated `string->symbol' before the name is interned, \
so a"
      "flood of distinct names fails closed naming the `interned-symbols'"
      "dimension rather than relying on the step budget as a proxy. Each call"
      "interns at most one new symbol, so the per-call charge is a conservativ\
e"
      "upper bound on the symbols the run adds to the global intern table."
      #((parameters
         (context (type symbol)
          (description
           ("Evaluation context whose interned-symbol counter is"
             "incremented and checked."))))
        (returns
         . ("The unspecified value, after possibly raising on budget"
            "exhaustion."))
        (effects state-write error))
      (set-context-interned-symbols!
       context
       (+ (context-interned-symbols context) 1))
      (if (> (context-interned-symbols context)
             (context-maximum-interned-symbols context))
          (budget-stop! context 'interned-symbols
                        "interned-symbol budget exceeded"
                        (context-interned-symbols context)
                        (context-maximum-interned-symbols context))))

    (define (note-output! context byte-count)
      "Charge BYTE-COUNT printed-output characters against the output budget."
      "Port writes charge what they emit as they emit it, so an unbounded"
      "printing loop fails closed with the dimension named, exactly like the"
      "step and host-callback budgets."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose output-byte counter is"
             "incremented and checked.")))
         (byte-count (type exact-integer)
          (description
            ("Number of output bytes to charge against the budget."))))
        (returns
         . ("The unspecified value, after possibly raising on budget"
            "exhaustion."))
        (effects state-write error))
      (set-context-output-bytes!
       context
       (+ (context-output-bytes context) byte-count))
      (if (> (context-output-bytes context)
             (context-maximum-output-bytes context))
          (budget-stop! context 'output-bytes
                        "output byte budget exceeded"
                        (context-output-bytes context)
                        (context-maximum-output-bytes context))))

    (define (note-value-allocation! context count)
      "Charge COUNT freshly allocated value nodes against the result budget."
      "Constructors charge what they allocate as they allocate it, so the"
      "budget bounds cumulative result growth in O(1) per operation rather"
      "than re-walking the reachable structure of every primitive result."
      "Enforcement fails closed with the unchanged \"value node budget"
      "exceeded\" diagnostic so an interpreted `guard` cannot catch it."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose value-node counter is incremented"
             "and checked.")))
         (count (type exact-integer)
          (description "Number of freshly allocated value nodes to charge.")))
        (returns
         . ("The unspecified value, after possibly raising on budget"
            "exhaustion."))
        (effects state-write error))
      (set-context-value-nodes!
       context
       (+ (context-value-nodes context) count))
      (if (> (context-value-nodes context)
             (context-maximum-value-nodes context))
          (budget-stop! context 'value-nodes
                        "value node budget exceeded"
                        (context-value-nodes context)
                        (context-maximum-value-nodes context))))

    (define (charge-value-allocation! value count context)
      "Charge COUNT allocated nodes against CONTEXT and return VALUE."
      "A convenience wrapper so a constructor charges its allocation inline"
      "and still yields the constructed value in tail position."
      #((parameters
         (value . "Constructed value to return after charging.")
         (count (type exact-integer)
          (description
            ("Number of allocated nodes to charge against the budget.")))
         (context (type eval-context)
          (description
            ("Evaluation context whose value-node budget is charged."))))
        (returns . "The original VALUE, unchanged.")
        (effects state-write error))
      (note-value-allocation! context count)
      value)

    (define (own-allocated-compound value context)
      "Return arbitrary VALUE imported into CONTEXT's compound datum heap."
      "Fresh linear constructors use kind-specific allocation below; this"
      "graph-aware fallback remains for values whose sharing or cycles must"
      "be discovered."
      (consent-datum-import
       (context-datum-heap context)
       value
       (lambda (leaf) leaf)
       (lambda (target source)
         (context-copy-datum-source! context target source #t))))

    (define (charge-string-allocation! value context)
      "Charge a freshly built string VALUE's nodes (1 + length) and return it.\
"
      #((parameters
         (value (type string)
          (description "Freshly built string to return after charging."))
         (context (type eval-context)
          (description
            ("Evaluation context whose value-node budget is charged."))))
        (returns (type string)
         (description "The original string VALUE, unchanged."))
        (effects state-write error))
      ;; VALUE is a fresh private adapter string. Copy its indexed contents
      ;; directly instead of allocating a host-identity registry for a graph
      ;; that cannot contain edges.
      (let ((owned
             (consent-datum-string-from-host
              (context-datum-heap context) value)))
        (note-value-allocation!
         context
         (+ 1 (consent-datum-string-length owned)))
        owned))

    (define (charge-bytevector-allocation! value context)
      "Charge a freshly built bytevector VALUE's nodes (1 + length) and return \
it."
      #((parameters
         (value (type bytevector)
          (description "Freshly built bytevector to return after charging."))
         (context (type eval-context)
          (description
            ("Evaluation context whose value-node budget is charged."))))
        (returns (type bytevector)
         (description "The original bytevector VALUE, unchanged."))
        (effects state-write error))
      ;; Bytevectors are flat. Their direct owner copies exactly LENGTH bytes
      ;; and never enters the graph importer.
      (let ((owned
             (consent-datum-bytevector-from-host
              (context-datum-heap context) value)))
        (note-value-allocation!
         context
         (+ 1 (consent-datum-bytevector-length owned)))
        owned))

    (define (charge-vector-allocation! value context)
      "Charge a freshly built vector VALUE's nodes (1 + length) and return it.\
"
      #((parameters
         (value (type vector)
          (description "Freshly built vector to return after charging."))
         (context (type eval-context)
          (description
            ("Evaluation context whose value-node budget is charged."))))
        (returns (type vector)
         (description "The original vector VALUE, unchanged."))
        (effects state-write error))
      ;; Interpreter constructors supply flat adapter vectors whose elements
      ;; are already canonical values. Validate/copy those slots directly;
      ;; encountering a host compound is a boundary bug, not a reason to run
      ;; graph discovery over every ordinary vector result.
      (let ((owned
             (consent-datum-vector-from-host-elements
              (context-datum-heap context) value)))
        (note-value-allocation!
         context
         (+ 1 (consent-datum-vector-length owned)))
        owned))

    (define (charge-list-allocation! value context)
      "Charge a freshly consed proper list VALUE's pairs (its length) and"
      "return it. The shared empty-list tail and the already-charged elements"
      "are not recounted."
      #((parameters
         (value (type list)
          (description
            ("Freshly consed proper list to return after charging.")))
         (context (type eval-context)
          (description
            ("Evaluation context whose value-node budget is charged."))))
        (returns (type list)
         (description "The original list VALUE, unchanged."))
        (effects state-write error))
      (if (not (proper-list? value))
          (eval-error "allocated list must be a proper list"))
      ;; Collect source nodes in reverse order, then allocate the visible spine
      ;; from its tail. This is three bounded linear passes including Floyd
      ;; validation, needs no identity registry, and leaves every fresh pair at
      ;; revision zero. Elements are reused unchanged, retaining their existing
      ;; ownership and source notes.
      (let collect ((cursor value) (nodes '()) (count 0))
        (if (null? cursor)
            (let build ((rest nodes) (result '()))
              (if (null? rest)
                  (charge-value-allocation! result count context)
                  (let ((source (car rest)))
                    (build
                     (cdr rest)
                     (consent-datum-cons
                      (context-datum-heap context)
                      (proper-list-node-car source)
                      result)))))
            (collect
             (proper-list-node-cdr cursor)
             (cons cursor nodes)
             (+ count 1)))))

    (define (value-node-atomic? value)
      "Report whether VALUE is one opaque node with no traversed children."
      (or (boolean? value)
          (null? value)
          (runtime-symbol? value)
          (identifier? value)
          (consent-character? value)
          ;; Public accessors can unwrap canonical numbers to host values.
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
          (consent-record-type? value)))

    (define (value-node-count value seen . maybe-tolerant)
      "Count the reachable nodes in VALUE while tolerating cycles."
      "An optional truthy MAYBE-TOLERANT argument counts unrecognized host"
      "values as opaque leaves instead of raising: under the"
      "internal-libraries grant, natively bound library procedures"
      "legitimately return their own host record types, so the"
      "canonical-value tripwire is relaxed only for that trusted posture."
      #((parameters
         (value . "Runtime value whose reachable nodes are counted.")
         (seen (type list)
          (description
           ("List of already-visited compound values for cycle"
             "tolerance.")))
         (maybe-tolerant (type list)
          (description
           ("Optional flag counting unrecognized host values as opaque"
             "leaves instead of raising."))))
        (returns (type exact-integer)
         (description
          ("The total count of reachable value nodes as a host"
            "integer.")))
        (effects error))
      (let ((tolerant (and (pair? maybe-tolerant) (car maybe-tolerant))))
        ;; Scalar results dominate budget checks; avoid allocating a worklist
        ;; or identity maps until VALUE can actually contain graph edges.
        (if (value-node-atomic? value)
            1
            (let ((visited (make-runtime-identity-map)))
              (dynamic-wind
               (lambda () #t)
               (lambda ()
                 ;; Preserve the historical SEEN parameter as initial state.
                 (let seed ((rest seen))
                   (if (not (null? rest))
                       (begin
                         (runtime-identity-map-set! visited (car rest) #t)
                         (seed (cdr rest)))))
                 ;; Count each identity-bearing graph node once. The explicit
                 ;; worklist prevents deep-stack failure and ancestor scans;
                 ;; shared DAGs therefore remain O(V + E), too.
                 (let loop ((work (list value)) (count 0))
                   (if (null? work)
                       count
                       (let* ((item (car work))
                              (rest (cdr work)))
                         (cond
                          ((value-node-atomic? item)
                           (loop rest (+ count 1)))
                 ((consent-record? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (let* ((fields (consent-record-fields item))
                             (owned? (consent-datum-vector? fields))
                             (length
                              (if owned?
                                  (consent-datum-vector-length fields)
                                  (vector-length fields))))
                        (runtime-identity-map-set! visited item #t)
                        (let push ((index (- length 1)) (next rest))
                          (if (< index 0)
                              (loop next (+ count 1))
                              (push
                               (- index 1)
                               (cons
                                (if owned?
                                    (consent-datum-vector-ref fields index)
                                    (vector-ref fields index))
                                next)))))))
                 ((multiple-values? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (let reverse-values
                            ((values (multiple-values-values item))
                             (reversed '()))
                          (if (null? values)
                              (let push ((values reversed) (next rest))
                                (if (null? values)
                                    (loop next (+ count 1))
                                    (push
                                     (cdr values)
                                     (cons (car values) next))))
                              (reverse-values
                               (cdr values)
                               (cons (car values) reversed)))))))
                 ((consent-datum-string? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (loop
                         rest
                         (+ count 1
                            (consent-datum-string-length item))))))
                 ((consent-datum-bytevector? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (loop
                         rest
                         (+ count 1
                            (consent-datum-bytevector-length item))))))
                 ((consent-datum-pair? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (loop
                         (cons
                          (consent-datum-car item)
                          (cons (consent-datum-cdr item) rest))
                         (+ count 1)))))
                 ((consent-datum-vector? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (let ((length (consent-datum-vector-length item)))
                        (runtime-identity-map-set! visited item #t)
                        (let push ((index (- length 1)) (next rest))
                          (if (< index 0)
                              (loop next (+ count 1))
                              (push
                               (- index 1)
                               (cons
                                (consent-datum-vector-ref item index)
                                next)))))))
                 ((string? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (loop rest (+ count 1 (string-length item))))))
                 ((bytevector? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (loop rest (+ count 1 (bytevector-length item))))))
                 ((pair? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (begin
                        (runtime-identity-map-set! visited item #t)
                        (loop
                         (cons (car item) (cons (cdr item) rest))
                         (+ count 1)))))
                 ((vector? item)
                  (if (runtime-identity-map-ref visited item #f)
                      (loop rest count)
                      (let ((length (vector-length item)))
                        (runtime-identity-map-set! visited item #t)
                        (let push ((index (- length 1)) (next rest))
                          (if (< index 0)
                              (loop next (+ count 1))
                              (push
                               (- index 1)
                               (cons (vector-ref item index) next)))))))
                       (tolerant (loop rest (+ count 1)))
                       (else
                        (eval-error
                         "unsupported Scheme value"
                         item)))))))
               (lambda ()
                 (runtime-identity-map-release! visited)))))))

    (define (check-value-budget value context)
      "Reject VALUE when its reachable node count exceeds the result budget."
      #((parameters
         (value . "Runtime value whose reachable node count is checked.")
         (context (type eval-context)
          (description "Evaluation context holding the value-node ceiling.")))
        (returns .
          ("The original VALUE when within budget; otherwise raises."))
        (effects state-write error))
      (let ((count (value-node-count
                    value
                    '()
                    (and context
                         (context-internal-libraries-allowed? context)))))
        (if (> count (context-maximum-value-nodes context))
            (budget-stop! context 'value-nodes
                          "value node budget exceeded"
                          count
                          (context-maximum-value-nodes context))))
      value)

    (define (charge-literal! value context)
      "Charge a quoted or self-evaluating literal's node count at evaluation."
      "Literals are realized from source rather than constructed, so they are"
      "budgeted by a single bounded walk over the source datum -- off the hot"
      "primitive path -- which keeps the literal result-size fixtures exact"
      "while the per-result walk is removed from constructor and accessor"
      "results."
      #((parameters
         (value . "Literal datum whose node count is charged.")
         (context (type eval-context)
          (description
            ("Evaluation context whose value-node budget is charged."))))
        (returns . "The original literal VALUE, unchanged.")
        (effects state-write error))
      (let ((owned (own-allocated-compound value context)))
        (note-value-allocation!
         context
         (value-node-count
          owned
          '()
          (and context (context-internal-libraries-allowed? context))))
        owned))

    (define (budget-spec-ref spec keys)
      "Return SPEC's first numeric value among KEYS as a host number, or #f."
      "SPEC is a `(budget (key value) ...)' datum or a bare field alist; KEYS"
      "lists the acceptable field names (so an alias such as `allocation-bytes\
'"
      "can stand in for `allocation-nodes')."
      #((parameters
         (spec (type list)
          (description
            ("Budget specification datum or field alist to search.")))
         (keys (type list)
          (description
           ("List of acceptable field names to look up, in priority"
             "order."))))
        (returns (type (or number boolean))
         (description
          ("The first matching numeric field value as a host number,"
            "or #f when none match.")))
        (effects pure))
      (let ((fields (if (and (pair? spec) (runtime-symbol-eq? (car spec)
        'budget))
                        (cdr spec)
                        spec)))
        (let loop ((remaining keys))
          (if (null? remaining)
              #f
              (let ((entry (and (list? fields) (runtime-assq (car remaining)
                fields))))
                (if (and (pair? entry) (pair? (cdr entry)))
                    (let ((value (cadr entry)))
                      (cond
                       ((consent-number? value) (consent-number-value value))
                       ((number? value) value)
                       (else (loop (cdr remaining)))))
                    (loop (cdr remaining))))))))

    (define (budget-spec-dimensions)
      "Return the counter dimensions a budget specification may tighten."
      "Each entry is (KEYS max-getter max-setter used-getter); KEYS are the"
      "specification field names that target the dimension."
      #((parameters)
        (returns (type list)
         (description
          ("A list of (keys max-getter max-setter used-getter)"
            "dimension descriptors.")))
        (effects pure))
      (list
       (list '(steps)
             context-maximum-steps set-context-maximum-steps!
             context-steps)
       (list '(host-callbacks)
             context-maximum-host-callbacks set-context-maximum-host-callbacks!
             context-host-callbacks)
       (list '(yields events)
             context-maximum-events set-context-maximum-events!
             context-event-count)
       (list '(allocation-nodes allocation-bytes)
             context-maximum-value-nodes set-context-maximum-value-nodes!
             context-value-nodes)
       (list '(source-metadata)
             context-maximum-source-metadata
             set-context-maximum-source-metadata!
             (lambda (context) (consent-source-metadata-count)))
       (list '(interned-symbols)
             context-maximum-interned-symbols
             set-context-maximum-interned-symbols!
             context-interned-symbols)
       (list '(output-bytes)
             context-maximum-output-bytes set-context-maximum-output-bytes!
             context-output-bytes)))

    (define (budget-ceiling-snapshot context)
      "Capture CONTEXT's current tightenable ceilings for later restoration."
      #((parameters
         (context (type eval-context)
          (description "Evaluation context whose ceilings are read.")))
        (returns (type list)
         (description
          ("A list of the current ceiling values, ordered by budget"
            "dimension.")))
        (effects state-read))
      (map (lambda (dimension) ((second dimension) context))
           (budget-spec-dimensions)))

    (define (budget-tighten! context spec)
      "Lower CONTEXT's counter ceilings to admit at most the SPEC amount more.\
"
      "A dimension absent from SPEC is left untouched, and the tightened ceili\
ng"
      "never rises above the inherited outer ceiling, so nested `with-budget'"
      "forms compose monotonically."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose ceilings are tightened in place.")))
         (spec (type list)
          (description
           ("Budget specification naming the dimensions and amounts to"
             "admit."))))
        (returns . "The unspecified value.")
        (effects state-read state-write))
      (for-each
       (lambda (dimension)
         (let ((requested (budget-spec-ref spec (car dimension))))
           (if requested
               (let ((current ((second dimension) context))
                     (setter (third dimension))
                     (used ((fourth dimension) context)))
                 (let ((tightened (+ used requested)))
                   (setter context
                           (if (< tightened current) tightened current)))))))
       (budget-spec-dimensions)))

    (define (budget-restore! context saved)
      "Restore CONTEXT's tightenable ceilings from a SAVED snapshot."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose ceilings are restored in place.")))
         (saved (type list)
          (description
           ("Snapshot list of ceiling values from"
             "budget-ceiling-snapshot."))))
        (returns . "The unspecified value.")
        (effects state-write))
      (for-each
       (lambda (dimension value) ((third dimension) context value))
       (budget-spec-dimensions)
       saved))

    (define (values-list value)
      "Unpack a single or multiple-value result into a list."
      #((parameters
         (value . "Single value or multiple-values result to unpack."))
        (returns (type list)
         (description "A list of the contained values."))
        (effects pure))
      (if (multiple-values? value)
          (multiple-values-values value)
          (list value)))

    (define (single-value value description)
      "Require VALUE to contain exactly one Scheme value."
      #((parameters
         (value . "Single value or multiple-values result to constrain.")
         (description (type string)
          (description
           ("Context phrase prefixed to the error when the count is not"
             "one."))))
        (returns
         . ("The single contained value; raises when VALUE holds zero"
            "or many values."))
        (effects error))
      (let ((values (values-list value)))
        (if (not (= (length values) 1))
            (eval-error
             (string-append description " expected one value")
             (length values)))
        (car values)))

    (define (identity-continuation value)
      "Default continuation that returns its input value unchanged."
      #((parameters
         (value . "Value to return unchanged."))
        (returns . "The original VALUE, unchanged.")
        (effects pure))
      value)

    (define (continue continuation value)
      "Invoke a continuation procedure with VALUE."
      #((parameters
         (continuation (type procedure)
          (description "Continuation procedure to invoke."))
         (value . "Value passed to the continuation."))
        (returns . "Whatever CONTINUATION returns when applied to VALUE.")
        (effects pure))
      (continuation value))

    (define (continuation-value arguments)
      "Package continuation arguments as one value or multiple values."
      #((parameters
         (arguments (type list)
          (description "List of values to package for the continuation.")))
        (returns
         . ("The sole value when ARGUMENTS has one element, else a"
            "multiple-values datum."))
        (effects pure))
      (if (= (length arguments) 1)
          (car arguments)
          (make-multiple-values arguments)))

    (define (proper-list-node? value)
      "Report whether VALUE is an owned or private host pair."
      (or (pair? value) (consent-datum-pair? value)))

    (define (proper-list-node-car pair)
      "Return owned or private host PAIR's car."
      (if (pair? pair)
          (car pair)
          (consent-datum-car pair)))

    (define (proper-list-node-cdr pair)
      "Return owned or private host PAIR's cdr."
      (if (pair? pair)
          (cdr pair)
          (consent-datum-cdr pair)))

    (define (proper-list-node-same? left right)
      "Report whether LEFT and RIGHT are the same mixed pair node."
      (and (proper-list-node? left)
           (proper-list-node? right)
           (or (eq? left right)
               (consent-datum-same? left right))))

    (define (proper-list? datum)
      "Report whether DATUM is a finite proper mixed Scheme list."
      ;; Floyd validation is O(n), constant-space, and allocates no identity
      ;; table on ordinary list validation paths.
      (let loop ((slow datum) (fast datum))
        (cond
         ((null? fast) #t)
         ((not (proper-list-node? fast)) #f)
         (else
          (let ((fast-one (proper-list-node-cdr fast)))
            (cond
             ((null? fast-one) #t)
             ((not (proper-list-node? fast-one)) #f)
             (else
              (let ((slow-one (proper-list-node-cdr slow))
                    (fast-two (proper-list-node-cdr fast-one)))
                (if (proper-list-node-same? slow-one fast-two)
                    #f
                    (loop slow-one fast-two))))))))))

    (define (proper-list-elements datum description)
      "Return DATUM's elements or reject an improper or cyclic spine."
      #((parameters
         (datum (type list)
          (description "Datum expected to be a proper list."))
         (description (type string)
          (description
           ("Context phrase prefixed to the error when DATUM is"
             "improper."))))
        (returns (type list)
         (description
          ("A fresh list of DATUM's elements; raises when DATUM is not"
            "a proper list.")))
        (effects error))
      (if (not (proper-list? datum))
          (eval-error
           (string-append description " must be a proper list")))
      ;; Validation proved the spine finite. Collection is a second linear,
      ;; map-free pass and allocates only the result list promised above.
      (let loop ((cursor datum) (elements '()))
        (if (null? cursor)
            (reverse elements)
            (loop
             (proper-list-node-cdr cursor)
             (cons (proper-list-node-car cursor) elements)))))

    ;; Documentation metadata fields whose list values append in source order.
    (define documentation-list-field-names '(examples see-also))

    (define (documentation-field fields name)
      "Return FIELDS entry named NAME, or #f."
      (runtime-assq name fields))

    (define (documentation-add-origin origins origin)
      "Return ORIGINS with ORIGIN appended once in source order."
      (if (runtime-memq origin origins)
          origins
          (append origins (list origin))))

    (define (documentation-set-field fields name value)
      "Return FIELDS with NAME set to VALUE, preserving field order."
      (if (documentation-field fields name)
          (map (lambda (field)
                 (if (runtime-symbol-eq? (car field) name)
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
                       " "
                       (documentation-join-strings (cdr strings))))))

    (define (documentation-normalize-description value)
      "Return VALUE as a normalized description string, or #f."
      (cond
       ((string? value) value)
       ((not (proper-list? value)) #f)
       (else
        (let loop ((rest value) (strings '()))
          (cond
           ((null? rest)
            (documentation-join-strings (reverse strings)))
                   ((string? (car rest))
                    (loop (cdr rest) (cons (car rest) strings)))
                   (else #f))))))

    (define (documentation-string-list? value)
      "Return #t when VALUE is a non-empty proper list of strings."
      (and (pair? value)
           (proper-list? value)
           (let loop ((rest value))
             (cond
              ((null? rest) #t)
              ((string? (car rest)) (loop (cdr rest)))
              (else #f)))))

    (define (documentation-descriptor-entry-value entry)
      "Return ENTRY's single value, or #f."
      (if (and (pair? entry)
               (pair? (cdr entry))
               (null? (cdr (cdr entry))))
          (car (cdr entry))
          #f))

    (define (documentation-normalize-descriptor value)
      "Return VALUE as a metadata descriptor, or #f."
      (cond
               ((string? value)
                (list (list 'type 'any)
                      (list 'description value)))
               ((documentation-string-list? value)
                (list (list 'type 'any)
                      (list 'description
                            (documentation-join-strings value))))
               ((not (proper-list? value)) #f)
       (else
        (let loop ((rest value)
                   (fields '())
                   (names '())
                   (type-present? #f))
          (cond
           ((null? rest)
            (let ((normalized (reverse fields)))
              (if type-present?
                  normalized
                  (cons (list 'type 'any) normalized))))
           ((not (pair? (car rest))) #f)
           ((not (runtime-symbol? (car (car rest)))) #f)
           ((runtime-memq (car (car rest)) names) #f)
           ((runtime-symbol-eq? (car (car rest)) 'type)
            (let ((entry-value
                   (documentation-descriptor-entry-value (car rest))))
              (if entry-value
                  (loop (cdr rest)
                        (cons (list 'type entry-value) fields)
                        (cons 'type names)
                        #t)
                  #f)))
           ((runtime-symbol-eq? (car (car rest)) 'description)
            (let ((entry-value
                   (documentation-descriptor-entry-value (car rest))))
              (if entry-value
                  (let ((description
                         (documentation-normalize-description entry-value)))
                    (if description
                        (loop (cdr rest)
                              (cons (list 'description description) fields)
                              (cons 'description names)
                              type-present?)
                        #f))
                  #f)))
           (else
            (loop (cdr rest)
                  (cons (car rest) fields)
                  (cons (car (car rest)) names)
                  type-present?)))))))

    (define (documentation-normalize-parameters parameters)
      "Return descriptor-shaped PARAMETERS, or #f when malformed."
      (if (not (proper-list? parameters))
          #f
          (let loop ((rest parameters) (normalized '()) (names '()))
            (cond
             ((null? rest) (reverse normalized))
             ((not (pair? (car rest))) #f)
             ((not (runtime-symbol? (car (car rest)))) #f)
             ((runtime-memq (car (car rest)) names) #f)
             (else
              (let ((descriptor
                     (documentation-normalize-descriptor
                      (cdr (car rest)))))
                (if descriptor
                    (loop (cdr rest)
                          (cons (cons (car (car rest)) descriptor)
                                normalized)
                          (cons (car (car rest)) names))
                    #f)))))))

    (define (documentation-parameter-names parameters)
      "Return `(ok . names)' for valid parameter alists, otherwise #f."
      (if (not (proper-list? parameters))
          #f
          (let loop ((rest parameters) (names '()))
            (cond
             ((null? rest) (cons 'ok (reverse names)))
             ((not (pair? (car rest))) #f)
             ((not (runtime-symbol? (car (car rest)))) #f)
             ((runtime-memq (car (car rest)) names) #f)
             (else
              (loop (cdr rest) (cons (car (car rest)) names)))))))

    (define (documentation-argument-names arguments)
      "Return `(ok . names)' for valid argument datums, otherwise #f."
      (cond
       ((runtime-symbol? arguments) (cons 'ok (list arguments)))
       (else
        (let loop ((cursor arguments) (names '()))
          (cond
           ((null? cursor) (cons 'ok (reverse names)))
           ((pair? cursor)
            (if (not (runtime-symbol? (car cursor)))
                #f
                (loop (cdr cursor) (cons (car cursor) names))))
           ((runtime-symbol? cursor) (cons 'ok (reverse (cons cursor names))))
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
                      ((runtime-memq (car rest) argument-names)
                       (loop (cdr rest) argument-names))
                      (else #f))))))))

    (define (documentation-merge-parameters fields value)
      "Return FIELDS merged with parameter metadata VALUE, or #f if malformed.\
"
      (let* ((normalized (documentation-normalize-parameters value))
             (new-names-result
              (and normalized (documentation-parameter-names normalized)))
             (existing (documentation-field fields 'parameters)))
        (if (not (and normalized new-names-result))
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
                           (append (cdr existing) normalized)))
                         ((runtime-memq (car rest) existing-names) #f)
                         (else
                          (duplicate-loop
                           (cdr rest)
                           existing-names)))))))
               (else
                (documentation-add-field fields 'parameters normalized)))))))

    (define (documentation-merge-returns fields value)
      "Return FIELDS merged with return metadata VALUE, or #f if malformed."
      (let ((normalized (documentation-normalize-descriptor value)))
        (cond
         ((not normalized) #f)
         ((documentation-field fields 'returns) #f)
         (else (documentation-add-field fields 'returns normalized)))))

    (define (documentation-merge-field fields name value)
      "Return FIELDS merged with NAME/VALUE, or #f if malformed."
      (let ((existing (documentation-field fields name)))
        (cond
         ((runtime-symbol-eq? name 'documentation)
          (if (not (string? value))
              #f
              (if existing
                  (if (string? (cdr existing))
                      (documentation-set-field
                       fields
                       name
                       (string-append (cdr existing) " " value))
                      #f)
                  (documentation-add-field fields name value))))
         ((runtime-symbol-eq? name 'parameters)
          (documentation-merge-parameters fields value))
         ((runtime-symbol-eq? name 'returns)
          (documentation-merge-returns fields value))
         ((runtime-memq name documentation-list-field-names)
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
               ((not (runtime-symbol? (car (car rest)))) #f)
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
      (if (and (pair? maybe-formals) (not (runtime-symbol-eq? retention
        'none)))
          (documentation-metadata-from-formals (car maybe-formals))
          (make-documentation-metadata '() '())))

    (define (documentation-body-result
             body body-definition-form? retention . maybe-formals)
      "Return `(metadata . body)' after reading documentation literals from BO\
DY."
      #((parameters
         (body (type list)
          (description
           ("Body form list whose leading documentation literals are"
             "read.")))
         (body-definition-form? (type procedure)
          (description
           ("Predicate recognizing internal definition forms to skip"
             "past.")))
         (retention (type symbol)
          (description
           ("Docstring retention mode controlling which metadata is"
             "kept.")))
         (maybe-formals (type list)
          (description
            ("Optional formals list used to validate parameter metadata."))))
        (returns (type pair)
         (description
          ("A pair of the parsed documentation metadata and the"
            "possibly rewritten body.")))
        (effects error))
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
                               (if (runtime-memq retention '(full simple))
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
                              (if (runtime-symbol-eq? retention 'full)
                                  merged-validation
                                  retained-metadata)
                              #t)
                        (finish rest retained-metadata))))
                 (else
                  (finish rest retained-metadata))))))))

    (define (documentation-metadata-from-body
             body body-definition-form? . maybe-formals)
      "Return full documentation metadata from BODY."
      #((parameters
         (body (type list)
          (description
           ("Body form list whose leading documentation literals are"
             "read.")))
         (body-definition-form? (type procedure)
          (description
           ("Predicate recognizing internal definition forms to skip"
             "past.")))
         (maybe-formals (type list)
          (description
            ("Optional formals list used to validate parameter metadata."))))
        (returns . "The full documentation metadata parsed from BODY.")
        (effects error))
      (car (apply documentation-body-result
                  body
                  body-definition-form?
                  'full
                  maybe-formals)))

    (define (second list)
      "Return the second element of LIST for parser helpers."
      #((parameters
         (list (type list)
          (description "List whose second element is returned.")))
        (returns (type list)
         (description "The second element of LIST."))
        (effects error))
      (car (cdr list)))

    (define (third list)
      "Return the third element of LIST for parser helpers."
      #((parameters
         (list (type list)
          (description "List whose third element is returned.")))
        (returns (type list)
         (description "The third element of LIST."))
        (effects error))
      (car (cdr (cdr list))))

    (define (fourth list)
      "Return the fourth element of LIST for parser helpers."
      #((parameters
         (list (type list)
          (description "List whose fourth element is returned.")))
        (returns (type list)
         (description "The fourth element of LIST."))
        (effects error))
      (car (cdr (cdr (cdr list)))))

    (define (expect-symbol datum description)
      "Validate that DATUM is a symbol for a named syntax context."
      #((parameters
         (datum (type symbol)
          (description "Datum required to be a bare symbol."))
         (description (type symbol)
          (description
           ("Context phrase prefixed to the error when DATUM is not a"
             "symbol."))))
        (returns (type symbol)
         (description "The symbol DATUM; raises when DATUM is not a symbol."))
        (effects error))
      (if (runtime-symbol? datum)
          datum
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    (define (identifier-datum? datum)
      "Report whether DATUM is a symbol or wrapped syntax identifier."
      #((parameters
         (datum (type symbol)
          (description "Datum to test for symbol or identifier shape.")))
        (returns (type boolean)
         (description
          ("#t when DATUM is a symbol or syntax identifier, #f"
            "otherwise.")))
        (effects pure))
      (or (runtime-symbol? datum) (identifier? datum)))

    (define (identifier-datum-name datum)
      "Return the symbolic name from a raw or wrapped identifier."
      #((parameters
         (datum (type symbol)
          (description
            ("Symbol or wrapped identifier to extract the name from."))))
        (returns (type (or symbol boolean))
         (description
           ("The underlying symbol name, or #f when DATUM is neither.")))
        (effects pure))
      (cond
       ((runtime-symbol? datum) datum)
       ((identifier? datum) (identifier-name datum))
       (else #f)))

    (define (identifier-key identifier)
      "Return the lookup key for an identifier, preserving macro context."
      #((parameters
         (identifier (type (or symbol identifier))
          (description
            ("Symbol or wrapped identifier whose lookup key is built."))))
        (returns (type (or symbol list))
         (description
          ("A context-tagged key list, the bare symbol, or raises on a"
            "non-identifier.")))
        (effects error))
      (cond
       ((identifier? identifier)
        (let ((context (identifier-context identifier)))
          (if context
              (list 'syntax
                    (syntax-context-id context)
                    (identifier-name identifier))
              (identifier-name identifier))))
       ((runtime-symbol? identifier) identifier)
       (else
        (eval-error "expected identifier" identifier))))

    (define (identifier-named? datum name)
      "Report whether DATUM names the given symbol after identifier unwrapping\
."
      #((parameters
         (datum (type symbol)
          (description "Symbol or wrapped identifier to compare."))
         (name (type symbol)
          (description "Symbol the datum is tested against.")))
        (returns (type boolean)
         (description "#t when DATUM unwraps to NAME, #f otherwise."))
        (effects pure))
      (let ((actual (identifier-datum-name datum)))
        (and actual (consent-host-symbol-eq? actual name))))

    (define (expect-identifier-key datum description)
      "Return an identifier lookup key or raise a syntax-specific error."
      #((parameters
         (datum (type (or symbol identifier))
          (description "Datum required to be a symbol or identifier."))
         (description (type string)
          (description
           ("Context phrase prefixed to the error when DATUM is not an"
             "identifier."))))
        (returns (type (or symbol list))
         (description
          ("The identifier lookup key; raises when DATUM is not an"
            "identifier.")))
        (effects error))
      (if (identifier-datum? datum)
          (identifier-key datum)
          (eval-error
           (string-append description " must be an identifier")
           datum)))

    (define (consent-make-empty-environment . maybe-parent)
      "Public constructor for a mutable lexical environment with an optional p\
arent."
      #((parameters
         (maybe-parent (type list)
          (description "Optional parent environment for the new frame.")))
        (returns (type environment)
         (description
          ("A fresh empty mutable environment, chained to the parent"
            "when given.")))
        (effects pure))
      (make-environment
       '()
       (if (null? maybe-parent) #f (car maybe-parent))
       '()))

    (define (frame-cell environment name)
      "Return the cell for NAME in ENVIRONMENT's current frame, or #f."
      #((parameters
         (environment (type environment)
          (description "Environment whose current frame is searched."))
         (name (type (or symbol list))
          (description "Binding name to look up in the frame.")))
        (returns (type (or cell boolean))
         (description
          ("The binding cell for NAME in the current frame, or #f when"
            "absent.")))
        (effects state-read))
      ;; Context-owned symbols make identity the common lookup path. Import
      ;; installation normalizes provider names into the consumer's table, so
      ;; lexical lookup does not need a name-comparison fallback.
      (let* ((frame (environment-frame environment))
             (cell (if (pair? name)
                       (host-assoc name frame)
                       (host-assq name frame))))
        (if cell (cdr cell) #f)))

    (define (environment-cell environment name)
      "Return the nearest lexical cell for NAME, walking parent environments."
      #((parameters
         (environment (type environment)
          (description
            ("Innermost environment to begin the lexical search from.")))
         (name (type (or symbol list))
          (description "Binding name to resolve.")))
        (returns (type (or cell boolean))
         (description
          ("The nearest enclosing binding cell for NAME, or #f when"
            "unbound.")))
        (effects state-read))
      (let loop ((cursor environment))
        (cond
         ((not cursor) #f)
         ((frame-cell cursor name) => (lambda (cell) cell))
         (else (loop (environment-parent cursor))))))

    (define (environment-cell-imported? environment cell)
      "Report whether CELL is marked imported in ENVIRONMENT or its parents."
      #((parameters
         (environment (type environment)
          (description "Innermost environment to begin searching from."))
         (cell (type cell)
          (description "Binding cell whose imported status is checked.")))
        (returns (type boolean)
         (description
          ("#t when CELL is bound under an imported name in any"
            "enclosing frame, #f otherwise.")))
        (effects state-read))
      (let environment-loop ((cursor environment))
        (and cursor
             (or (let frame-loop ((frame (environment-frame cursor)))
                   (and (not (null? frame))
                        (or (and (runtime-symbol-eq? (cdr (car frame)) cell)
                                 (or (host-memq
                                      (car (car frame))
                                      (environment-imported-names cursor))
                                     (consent-host-symbol-memq
                                      (car (car frame))
                                      (environment-imported-names cursor))))
                            (frame-loop (cdr frame)))))
                 (environment-loop (environment-parent cursor))))))

    (define (current-environment-imported? environment name)
      "Report whether NAME is an imported binding in ENVIRONMENT's own frame."
      #((parameters
         (environment (type environment)
          (description
            ("Environment whose own imported-name list is consulted.")))
         (name (type (or symbol list))
          (description "Binding name to test.")))
        (returns (type (or list boolean))
         (description
          ("A non-#f tail when NAME is imported in this frame, #f"
            "otherwise.")))
        (effects state-read))
      (or (host-memq name (environment-imported-names environment))
          (consent-host-symbol-memq
           name
           (environment-imported-names environment))))

    (define (environment-define! environment name value . maybe-context)
      "Add NAME to ENVIRONMENT's current frame unless it would redefine import\
."
      #((parameters
         (environment (type environment)
          (description "Environment whose current frame gains the binding."))
         (name (type (or symbol list))
          (description "Binding name to define."))
         (value . "Initial value stored in the new binding cell.")
         (maybe-context (type list)
          (description
           "Zero or one evaluation context owning the binding cell.")))
        (returns
         . ("The unspecified value; raises when NAME shadows an"
            "imported binding."))
        (effects state-write error))
      (if (current-environment-imported? environment name)
          (eval-error "cannot redefine imported binding" name))
      (if (not (null? maybe-context))
          (ensure-environment-context-heap!
           environment (car maybe-context)))
      (set-environment-frame!
       environment
       (cons (cons name (if (null? maybe-context)
                            (make-cell value)
                            (make-cell value (car maybe-context))))
             (environment-frame environment))))

    (define (environment-set! environment name value context)
      "Mutate an existing lexical binding, rejecting unbound and imported name\
s."
      #((parameters
         (environment (type environment)
          (description
            ("Innermost environment whose binding chain is searched.")))
         (name (type (or symbol list))
          (description "Binding name to mutate."))
         (value . "New value stored in the resolved binding cell.")
         (context (type eval-context)
          (description "Context whose heap observes the mutation.")))
        (returns
         . ("The unspecified value; raises when NAME is unbound or"
            "imported."))
        (effects state-write error))
      (let ((cell (environment-cell environment name)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!" name))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding" name))
         (else
          (context-cell-set! context cell 'binding-set! value)))))

    (define (environment-define-or-set! environment name value context)
      "Update NAME in the current frame, or define it if no current cell exist\
s."
      #((parameters
         (environment (type environment)
          (description
            ("Environment whose current frame is updated or extended.")))
         (name (type (or symbol list))
          (description "Binding name to update or define."))
         (value . "Value stored in the binding cell.")
         (context (type eval-context)
          (description "Context whose heap observes an update.")))
        (returns
         . ("The unspecified value; raises when NAME shadows an"
            "imported binding."))
        (effects state-write error))
      (let ((cell (frame-cell environment name)))
        (if cell
            (begin
              (if (current-environment-imported? environment name)
                  (eval-error "cannot redefine imported binding" name))
              (context-cell-set! context cell 'binding-define! value))
            (environment-define! environment name value context))))

    (define (environment-ref environment name)
      "Return NAME's value, rejecting unbound or still-undefined bindings."
      #((parameters
         (environment (type environment)
          (description
            ("Innermost environment whose binding chain is searched.")))
         (name (type (or symbol list))
          (description "Binding name to resolve.")))
        (returns
         . ("The value bound to NAME; raises when NAME is unbound or"
            "uninitialized."))
        (effects state-read error))
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
      "Hygienic identifiers first try their generated lexical key at the use"
      "site, then fall back to the macro definition environment for free"
      "template identifiers."
      #((parameters
         (environment (type environment)
          (description "Use-site environment to resolve the identifier in."))
         (identifier (type (or symbol identifier))
          (description "Symbol or hygienic identifier to resolve.")))
        (returns (type (or cell boolean))
         (description
          ("The resolved binding cell, or #f when the identifier is"
            "unbound.")))
        (effects state-read))
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
       ((runtime-symbol? identifier)
        (environment-cell environment identifier))
       (else #f)))

    (define (environment-ref-identifier environment identifier)
      "Return IDENTIFIER's value after hygienic lookup and undefined checks."
      #((parameters
         (environment (type environment)
          (description "Use-site environment to resolve the identifier in."))
         (identifier (type (or symbol identifier))
          (description "Symbol or hygienic identifier to dereference.")))
        (returns
         . ("The value bound to IDENTIFIER; raises when unbound or"
            "uninitialized."))
        (effects state-read error))
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (if (not cell)
            (eval-error "unbound identifier" (identifier-datum-name
              identifier))
            (let ((value (cell-value cell)))
              (if (undefined? value)
                  (eval-error
                   "identifier referenced before definition is initialized"
                   (identifier-datum-name identifier))
                  value)))))

    (define (environment-set-identifier!
             environment identifier value context)
      "Mutate IDENTIFIER's binding after hygienic lookup and import checks."
      #((parameters
         (environment (type environment)
          (description "Use-site environment to resolve the identifier in."))
         (identifier (type (or symbol identifier))
          (description
            ("Symbol or hygienic identifier whose binding is mutated.")))
         (value . "New value stored in the resolved binding cell.")
         (context (type eval-context)
          (description "Context whose heap observes the mutation.")))
        (returns
         . ("The unspecified value; raises when IDENTIFIER is unbound"
            "or imported."))
        (effects state-write error))
      (let ((cell (environment-cell-for-identifier environment identifier)))
        (cond
         ((not cell)
          (eval-error "unbound identifier in set!"
                      (identifier-datum-name identifier)))
         ((environment-cell-imported? environment cell)
          (eval-error "cannot mutate imported binding"
                      (identifier-datum-name identifier)))
         (else
          (context-cell-set! context cell 'binding-set! value)))))

    (define (ensure-distinct-names names description)
      "Reject duplicate symbols in NAMES using DESCRIPTION for diagnostics."
      #((parameters
         (names (type (list-of (or symbol list)))
          (description "List of names checked for duplicates."))
         (description (type string)
          (description
           ("Context phrase prefixed to the error when a duplicate is"
             "found."))))
        (returns .
          ("The unspecified value; raises on the first duplicate name."))
        (effects error))
      (let loop ((rest names) (seen '()))
        (if (not (null? rest))
            (begin
              (if (runtime-memq (car rest) seen)
                  (eval-error
                   (string-append "duplicate identifier in " description)
                   (car rest)))
              (loop (cdr rest) (cons (car rest) seen))))))

    (define (parse-formals formals)
      "Parse lambda formals into required-name and optional-rest metadata."
      #((parameters
         (formals (type (or symbol identifier list pair))
          (description
           ("Lambda formals: a symbol, a proper list, or a dotted list"
             "of identifiers."))))
        (returns (type formals)
         (description
          ("A formals record of required-name keys and an optional"
            "rest key; raises on malformed formals.")))
        (effects error))
      (cond
       ((runtime-symbol? formals)
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
             "lambda formals must be an identifier, a proper list, or a dotted \
list"
             formals)))))))

    ))
