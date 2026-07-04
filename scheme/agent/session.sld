;;; Portable Consent Scheme session lifecycle records.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral session lifecycle model as
;;; Scheme-readable datums.  Host adapters can layer live environments, handles,
;;; jobs, and persistence over these records while preserving the same state
;;; names and snapshot rules.

(define-library (agent session)
  (export consent-session-scopes
          consent-session-states
          consent-session-restored-fields
          consent-session-revalidated-fields
          consent-session-never-restored-fields
          consent-make-session-store
          consent-session-store?
          session-store-create!
          session-store-ref
          session-store-list
          session-store-suspend!
          session-store-resume!
          session-store-snapshot!
          session-store-fork!
          session-store-retire!
          session-create!
          session-ref
          session-list
          session-suspend!
          session-resume!
          session-snapshot!
          session-fork!
          session-retire!
          session-handles
          session-datum-id
          consent-make-session-manager
          consent-session-manager?
          session-manager-store
          session-manager-set-context-factory!
          session-manager-context-factory
          session-manager-reset!
          session-manager-context-ref
          session-manager-current-id
          session-manager-create!
          session-manager-seed!
          session-manager-switch!
          session-manager-current
          session-manager-list
          session-manager-close!)
  (import (scheme base)
          (only (stdlib list) alist-delete filter-map))
  (begin
    ;; Session scopes distinguish one-off evaluation from named REPL and
    ;; project-rooted workspaces.
    (define consent-session-scopes
      '(fresh named project))

    ;; Lifecycle states are public data so snapshots and audit entries can be
    ;; interpreted without host internals.
    (define consent-session-states
      '(new active idle suspended retired failed collectable))

    ;; Fields in this list are ordinary Scheme data that can be restored from a
    ;; snapshot without host object authority.
    (define consent-session-restored-fields
      '(imports definitions macros memory-bindings capability-grant-requests
                transcripts recent-yields))

    ;; Fields in this list may survive as references, but a host must validate
    ;; them before use.
    (define consent-session-revalidated-fields
      '(project-root handle-references capability-grants skill-activations))

    ;; Fields in this list are intentionally excluded from blind restoration.
    (define consent-session-never-restored-fields
      '(stale-emacs-handles active-jobs approval-decisions provider-secrets
                            host-runtime-internals))

    ;; Mutable store for portable tests and host-neutral lifecycle operations.
    (define-record-type <consent-session-store>
      (make-session-store sessions next-session-number next-snapshot-number)
      consent-session-store?
      (sessions store-sessions set-store-sessions!)
      (next-session-number store-next-session-number
                           set-store-next-session-number!)
      (next-snapshot-number store-next-snapshot-number
                            set-store-next-snapshot-number!))

    ;; Mutable portable session record.  The exported surface is still the
    ;; Scheme-readable datum returned by session->datum.
    (define-record-type <consent-session>
      (make-session id scope status imports definitions macros memory handles
                    transcript recent-events snapshots parent-id forked-from)
      session?
      (id session-id)
      (scope session-scope)
      (status session-status set-session-status!)
      (imports session-imports set-session-imports!)
      (definitions session-definitions set-session-definitions!)
      (macros session-macros set-session-macros!)
      (memory session-memory set-session-memory!)
      (handles session-record-handles set-session-record-handles!)
      (transcript session-transcript set-session-transcript!)
      (recent-events session-recent-events set-session-recent-events!)
      (snapshots session-snapshots set-session-snapshots!)
      (parent-id session-parent-id)
      (forked-from session-forked-from))

    ;; Live session manager: the multi-environment-native layer over the pure
    ;; lifecycle store.  It owns a store of session records, a map of session id
    ;; to live host interaction context (each its own sandbox environment), a
    ;; default session id the REPL evaluates subsequent forms in, and an
    ;; injected context factory so this host-neutral library never imports the
    ;; interpreter that builds interaction contexts.
    (define-record-type <consent-session-manager>
      (make-session-manager store contexts default-id context-factory)
      consent-session-manager?
      (store manager-store set-manager-store!)
      (contexts manager-contexts set-manager-contexts!)
      (default-id manager-default-id set-manager-default-id!)
      (context-factory manager-context-factory set-manager-context-factory!))

    (define (consent-make-session-store)
      "Construct an empty portable session store."
      #((parameters)
        (returns (type consent-session-store)
         (description
          ("A mutable session store with no durable sessions and fresh"
            "id counters.")))
        (effects allocation))
      (make-session-store '() 0 0))

    ;; Default process-local store used by the legacy pure `session-*' API.
    (define default-session-store
      (consent-make-session-store))

    (define (member-equal? value list)
      "Report whether VALUE is in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (if (member-equal? scope consent-session-scopes)
          scope
          (error "unknown session scope" scope)))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT if absent."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (generated-session-id store scope)
      (let ((next (+ (store-next-session-number store) 1)))
        (set-store-next-session-number! store next)
        (string->symbol
         (string-append (symbol->string scope)
                        "-"
                        (number->string next)))))

    (define (generated-snapshot-id store)
      "Generate a fresh snapshot id in STORE."
      (let ((next (+ (store-next-snapshot-number store) 1)))
        (set-store-next-snapshot-number! store next)
        (string->symbol
         (string-append "snapshot-" (number->string next)))))

    (define (find-session store id)
      "Return the session object named ID from STORE, or #f."
      (let ((cell (assq id (store-sessions store))))
        (if cell (cdr cell) #f)))

    (define (store-session! store session)
      "Add SESSION to STORE unless a durable session with the same id exists."
      (if (not (eq? (session-scope session) 'fresh))
          (begin
            (if (find-session store (session-id session))
                (error "session already exists" (session-id session)))
            (set-store-sessions!
             store
             (cons (cons (session-id session) session)
                   (store-sessions store))))))

    (define (session->datum session)
      "Return SESSION as a Scheme-readable datum."
      (append
       (list 'session
             (list 'id (session-id session))
             (list 'scope (session-scope session))
             (list 'status (session-status session)))
       (if (session-parent-id session)
           (list (list 'parent-id (session-parent-id session)))
           '())
       (if (session-forked-from session)
           (list (list 'forked-from (session-forked-from session)))
           '())
       (list
        (list 'imports (session-imports session))
        (list 'definitions (session-definitions session))
        (list 'macros (session-macros session))
        (list 'memory (session-memory session))
        (list 'handles (session-record-handles session))
        (list 'transcript (session-transcript session))
        (list 'recent-events (session-recent-events session))
        (list 'snapshots
              (map (lambda (snapshot)
                     (cadr (cadr snapshot)))
                   (session-snapshots session))))))

    (define (session-datum-id session-datum)
      "Return the id field from a public SESSION-DATUM."
      #((parameters
         (session-datum (type list)
          (description "Public session datum.")))
        (returns (type symbol)
         (description "The session id field."))
        (effects pure))
      (cadr (cadr session-datum)))

    (define (session-datum-field session-datum name)
      "Return NAME from public SESSION-DATUM, or #f."
      (let loop ((fields (cdr session-datum)))
        (cond
         ((null? fields) #f)
         ((eq? (caar fields) name) (car fields))
         (else (loop (cdr fields))))))

    (define (session-handles session-datum)
      "Return handle references recorded in public SESSION-DATUM."
      #((parameters
         (session-datum (type list)
          (description "Public session datum.")))
        (returns (type list)
         (description "The session datum's `handles` field."))
        (effects pure))
      (let ((field (session-datum-field session-datum 'handles)))
        (if field (cadr field) '())))

    (define (session-store-create! store scope options)
      "Create a session in STORE for SCOPE using OPTIONS."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to mutate."))
         (scope (type symbol)
          (description "Session scope symbol."))
         (options (type list)
          (description
           ("Association list overriding id and initial construction"
             "fields."))))
        (returns (type list)
         (description "The created public session datum."))
        (effects state-write error))
      (let* ((normalized-scope (normalize-scope scope))
             (id (option-ref options
                             'id
                             (generated-session-id store normalized-scope)))
             (status (if (eq? normalized-scope 'fresh)
                         'collectable
                         'new))
             (session
              (make-session id
                            normalized-scope
                            status
                            '()
                            '()
                            '()
                            '()
                            '()
                            '()
                            '()
                            '()
                            #f
                            #f)))
        (store-session! store session)
        (session->datum session)))

    (define (session-store-ref store id)
      "Return a session datum by ID from STORE, or #f."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to search."))
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type (or list boolean))
         (description "The public session datum, or #f when ID is unknown."))
        (effects state-read))
      (let ((session (find-session store id)))
        (if session (session->datum session) #f)))

    (define (session-store-list store . maybe-scope)
      "Return session datums from STORE, optionally filtered by SCOPE."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to inspect."))
         (maybe-scope (type list)
          (description "Optional session scope symbol.")))
        (returns (type (list-of list))
         (description "List of public session datums in creation order."))
        (effects state-read error))
      (let ((scope (if (null? maybe-scope)
                       #f
                       (normalize-scope (car maybe-scope)))))
        (filter-map
         (lambda (cell)
           (and (or (not scope) (eq? (session-scope (cdr cell)) scope))
                (session->datum (cdr cell))))
         (store-sessions store))))

    (define (require-session store id)
      "Return the session object named ID from STORE or raise an error."
      (let ((session (find-session store id)))
        (if session
            session
            (error "unknown session" id))))

    (define (transition! session status)
      "Move SESSION to STATUS and return its public datum."
      (if (not (member-equal? status consent-session-states))
          (error "unknown session status" status))
      (set-session-status! session status)
      (session->datum session))

    (define (session-store-suspend! store id)
      "Suspend session ID in STORE."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to mutate."))
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type list)
         (description "The suspended public session datum."))
        (effects state-write error))
      (transition! (require-session store id) 'suspended))

    (define (session-store-resume! store id)
      "Resume session ID in STORE."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to mutate."))
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type list)
         (description "The active public session datum."))
        (effects state-write error))
      (transition! (require-session store id) 'active))

    (define (snapshot-datum session snapshot-id)
      "Build a snapshot record for SESSION using SNAPSHOT-ID."
      (list 'session-snapshot
            (list 'id snapshot-id)
            (list 'source-session (session-id session))
            (list 'scope (session-scope session))
            (list 'status (session-status session))
            (list 'imports (session-imports session))
            (list 'definitions (session-definitions session))
            (list 'macros (session-macros session))
            (list 'memory (session-memory session))
            (list 'handles (session-record-handles session))
            (list 'stale-handles '())
            (list 'transcript (session-transcript session))
            (list 'recent-events (session-recent-events session))
            (list 'restores consent-session-restored-fields)
            (list 'revalidates consent-session-revalidated-fields)
            (list 'never-restore consent-session-never-restored-fields)))

    (define (session-store-snapshot! store id options)
      "Snapshot session ID in STORE using OPTIONS."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to mutate."))
         (id (type symbol)
          (description "Session id symbol."))
         (options (type list)
          (description ("Association list overriding the generated snapshot id."))))
        (returns (type list)
         (description "A `session-snapshot` datum."))
        (effects state-write error))
      (let* ((session (require-session store id))
             (snapshot-id
              (option-ref options 'id (generated-snapshot-id store)))
             (snapshot (snapshot-datum session snapshot-id)))
        (set-session-snapshots!
         session
         (cons snapshot (session-snapshots session)))
        snapshot))

    (define (session-store-fork! store id options)
      "Fork session ID in STORE using OPTIONS and return the fork datum."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to mutate."))
         (id (type symbol)
          (description "Source session id symbol."))
         (options (type list)
          (description "Association list overriding the generated fork id.")))
        (returns (type list)
         (description "The forked public session datum."))
        (effects state-write error))
      (let* ((source (require-session store id))
             (fork-id
              (option-ref options
                          'id
                          (generated-session-id store
                                                (session-scope source))))
             (fork
              (make-session fork-id
                            (session-scope source)
                            'new
                            (session-imports source)
                            (session-definitions source)
                            (session-macros source)
                            (session-memory source)
                            (session-record-handles source)
                            (session-transcript source)
                            (session-recent-events source)
                            '()
                            (session-id source)
                            (session-id source))))
        (store-session! store fork)
        (session->datum fork)))

    (define (session-store-retire! store id)
      "Retire session ID in STORE and return its datum."
      #((parameters
         (store (type consent-session-store)
          (description "Session store to mutate."))
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type list)
         (description
          ("The retired public session datum with live handles"
            "cleared.")))
        (effects state-write error))
      (let ((session (require-session store id)))
        (set-session-record-handles! session '())
        (transition! session 'retired)))

    (define (session-create! scope . maybe-options)
      "Create a session in the default portable store."
      #((parameters
         (scope (type symbol)
          (description "Session scope symbol."))
         (maybe-options (type list)
          (description "Zero or one association list of construction fields.")))
        (returns (type list)
         (description "The created public session datum."))
        (effects state-write error))
      (session-store-create! default-session-store
                             scope
                             (if (null? maybe-options)
                                 '()
                                 (car maybe-options))))

    (define (session-ref id)
      "Return a session datum from the default portable store, or #f."
      #((parameters
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type (or list boolean))
         (description "The public session datum, or #f when ID is unknown."))
        (effects state-read))
      (session-store-ref default-session-store id))

    (define (session-list . maybe-scope)
      "Return default-store session datums, optionally filtered by scope."
      #((parameters
         (maybe-scope (type list)
          (description "Optional session scope symbol.")))
        (returns (type (list-of list))
         (description "List of public session datums."))
        (effects state-read error))
      (apply session-store-list default-session-store maybe-scope))

    (define (session-suspend! id)
      "Suspend default-store session ID."
      #((parameters
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type list)
         (description "The suspended public session datum."))
        (effects state-write error))
      (session-store-suspend! default-session-store id))

    (define (session-resume! id)
      "Resume default-store session ID."
      #((parameters
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type list)
         (description "The active public session datum."))
        (effects state-write error))
      (session-store-resume! default-session-store id))

    (define (session-snapshot! id . maybe-options)
      "Snapshot default-store session ID."
      #((parameters
         (id (type symbol)
          (description "Session id symbol."))
         (maybe-options (type list)
          (description "Zero or one association list overriding the snapshot id.")))
        (returns (type list)
         (description "A `session-snapshot` datum."))
        (effects state-write error))
      (session-store-snapshot! default-session-store
                               id
                               (if (null? maybe-options)
                                   '()
                                   (car maybe-options))))

    (define (session-fork! id . maybe-options)
      "Fork default-store session ID."
      #((parameters
         (id (type symbol)
          (description "Source session id symbol."))
         (maybe-options (type list)
          (description "Zero or one association list overriding the fork id.")))
        (returns (type list)
         (description "The forked public session datum."))
        (effects state-write error))
      (session-store-fork! default-session-store
                           id
                           (if (null? maybe-options)
                               '()
                               (car maybe-options))))

    (define (session-retire! id)
      "Retire default-store session ID."
      #((parameters
         (id (type symbol)
          (description "Session id symbol.")))
        (returns (type list)
         (description "The retired public session datum."))
        (effects state-write error))
      (session-store-retire! default-session-store id))

    (define (consent-make-session-manager)
      "Construct an empty live session manager."
      #((parameters)
        (returns (type consent-session-manager)
         (description
          ("A session manager with an empty store, no live contexts,"
            "no default session, and no context factory.")))
        (effects allocation))
      (make-session-manager (consent-make-session-store) '() #f #f))

    (define (session-manager-set-context-factory! manager factory)
      "Install FACTORY as MANAGER's interaction-context factory."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to configure."))
         (factory (type procedure)
          (description
           ("Procedure of (id scope options) returning a live"
             "interaction context for a session."))))
        (returns . "Unspecified.")
        (effects state-write))
      (set-manager-context-factory! manager factory))

    (define (session-manager-context-factory manager)
      "Return MANAGER's installed interaction-context factory, or #f."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to inspect.")))
        (returns (type (or procedure boolean))
         (description
          ("The installed context factory procedure, or #f when none"
            "is set.")))
        (effects state-read))
      (manager-context-factory manager))

    (define (session-manager-reset! manager)
      "Clear MANAGER's sessions, live contexts, and default session."
      "The manager is process-local and shared across evaluations, so a REPL"
      "run resets it at the start to keep multiple runs in one process (tests,"
      "embeddings) from leaking sessions or already-imported environments."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to reset.")))
        (returns . ("Unspecified. The installed context factory is preserved."))
        (effects state-write))
      (set-manager-store! manager (consent-make-session-store))
      (set-manager-contexts! manager '())
      (set-manager-default-id! manager #f))

    (define (session-manager-store manager)
      "Return MANAGER's underlying lifecycle store."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to inspect.")))
        (returns (type consent-session-store)
         (description "The manager's session store."))
        (effects state-read))
      (manager-store manager))

    (define (session-manager-current-id manager)
      "Return MANAGER's default session id, or #f when none is selected."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to inspect.")))
        (returns (type (or symbol boolean))
         (description "The default session id symbol, or #f."))
        (effects state-read))
      (manager-default-id manager))

    (define (manager-context-cell manager id)
      "Return the (id . context) cell for ID in MANAGER, or #f."
      (let loop ((cells (manager-contexts manager)))
        (cond
         ((null? cells) #f)
         ((eq? (caar cells) id) (car cells))
         (else (loop (cdr cells))))))

    (define (session-manager-context-ref manager id)
      "Return MANAGER's live interaction context for ID, or #f when absent."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to inspect."))
         (id (type symbol)
          (description "Session id symbol.")))
        (returns . "The live interaction context for ID, or #f.")
        (effects state-read))
      (let ((cell (manager-context-cell manager id)))
        (if cell (cdr cell) #f)))

    (define (manager-build-context manager id scope options)
      "Build a live interaction context for ID through MANAGER's factory."
      (let ((factory (manager-context-factory manager)))
        (if (not factory)
            (error "session manager has no interaction-context factory" id))
        (factory id scope options)))

    (define (manager-register-context! manager id context)
      "Store CONTEXT under ID in MANAGER, replacing any prior cell."
      (set-manager-contexts!
       manager
       (cons (cons id context)
             (alist-delete id (manager-contexts manager) eq?))))

    (define (session-manager-create! manager scope options)
      "Create a SCOPE session in MANAGER with a fresh sandbox context."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to mutate."))
         (scope (type symbol)
          (description "Session scope symbol."))
         (options (type list)
          (description ("Association list overriding id and construction fields."))))
        (returns (type list)
         (description
          ("The created public session datum. Does not change the"
            "default session.")))
        (effects state-write error))
      (let* ((datum (session-store-create! (manager-store manager) scope options))
             (id (session-datum-id datum)))
        (manager-register-context!
         manager id (manager-build-context manager id scope options))
        datum))

    (define (session-manager-seed! manager id scope context)
      "Register a pre-built CONTEXT as session ID (SCOPE) and make it default."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to mutate."))
         (id (type symbol)
          (description "Session id symbol for the seeded session."))
         (scope (type symbol)
          (description "Session scope symbol."))
         (context . "Pre-built live interaction context to adopt."))
        (returns (type list)
         (description
          ("The seeded public session datum, now the default session.")))
        (effects state-write error))
      (let ((datum (session-store-create! (manager-store manager)
                                    scope
                                    (list (list 'id id)))))
        (manager-register-context! manager id context)
        (set-manager-default-id! manager id)
        datum))

    (define (session-manager-switch! manager id)
      "Make ID MANAGER's default session, building a context if needed."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to mutate."))
         (id (type symbol)
          (description "Existing session id symbol to switch to.")))
        (returns (type (or list boolean))
         (description "ID's public session datum, or #f when ID is unknown."))
        (effects state-write))
      (let ((datum (session-store-ref (manager-store manager) id)))
        (if datum
            (begin
              (if (not (session-manager-context-ref manager id))
                  (manager-register-context!
                   manager id (manager-build-context manager id #f '())))
              (set-manager-default-id! manager id)
              datum)
            #f)))

    (define (session-manager-current manager)
      "Return MANAGER's default session datum, or #f when none is selected."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to inspect.")))
        (returns (type (or list boolean))
         (description "The default session's public datum, or #f."))
        (effects state-read))
      (let ((id (manager-default-id manager)))
        (if id (session-store-ref (manager-store manager) id) #f)))

    (define (session-manager-list manager . maybe-scope)
      "Return MANAGER's session datums, optionally filtered by SCOPE."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to inspect."))
         (maybe-scope (type list)
          (description "Optional session scope symbol.")))
        (returns (type (list-of list))
         (description "List of public session datums in creation order."))
        (effects state-read error))
      (apply session-store-list (manager-store manager) maybe-scope))

    (define (session-manager-close! manager id)
      "Retire session ID in MANAGER and drop its live context."
      #((parameters
         (manager (type consent-session-manager)
          (description "Session manager to mutate."))
         (id (type symbol)
          (description "Session id symbol to retire.")))
        (returns (type list)
         (description "The retired public session datum."))
        (effects state-write error))
      (let ((datum (session-store-retire! (manager-store manager) id)))
        (set-manager-contexts!
         manager
         (alist-delete id (manager-contexts manager) eq?))
        (if (eq? (manager-default-id manager) id)
            (set-manager-default-id! manager #f))
        datum))))
