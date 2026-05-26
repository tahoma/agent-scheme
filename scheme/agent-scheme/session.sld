;;; Portable Agent Scheme session lifecycle records.
;;;
;;; This library owns the host-neutral session lifecycle model as
;;; Scheme-readable datums.  Host adapters can layer live environments, handles,
;;; jobs, and persistence over these records while preserving the same state
;;; names and snapshot rules.

(define-library (agent-scheme session)
  (export agent-scheme-session-scopes
          agent-scheme-session-states
          agent-scheme-session-restored-fields
          agent-scheme-session-revalidated-fields
          agent-scheme-session-never-restored-fields
          agent-scheme-make-session-store
          agent-scheme-session-store?
          session-create!
          session-ref
          session-list
          session-suspend!
          session-resume!
          session-snapshot!
          session-fork!
          session-retire!
          session-datum-id)
  (import (scheme base))
  (begin
    ;; Session scopes distinguish one-off evaluation from named REPL and
    ;; project-rooted workspaces.
    (define agent-scheme-session-scopes
      '(fresh named project))

    ;; Lifecycle states are public data so snapshots and audit entries can be
    ;; interpreted without host internals.
    (define agent-scheme-session-states
      '(new active idle suspended retired failed collectable))

    ;; Fields in this list are ordinary Scheme data that can be restored from a
    ;; snapshot without host object authority.
    (define agent-scheme-session-restored-fields
      '(imports definitions macros memory-bindings capability-grant-requests
                transcripts recent-yields))

    ;; Fields in this list may survive as references, but a host must validate
    ;; them before use.
    (define agent-scheme-session-revalidated-fields
      '(project-root handle-references capability-grants skill-activations))

    ;; Fields in this list are intentionally excluded from blind restoration.
    (define agent-scheme-session-never-restored-fields
      '(stale-emacs-handles active-jobs approval-decisions provider-secrets
                            host-runtime-internals))

    ;; Mutable store for portable tests and host-neutral lifecycle operations.
    (define-record-type <agent-scheme-session-store>
      (make-session-store sessions next-session-number next-snapshot-number)
      agent-scheme-session-store?
      (sessions store-sessions set-store-sessions!)
      (next-session-number store-next-session-number
                           set-store-next-session-number!)
      (next-snapshot-number store-next-snapshot-number
                            set-store-next-snapshot-number!))

    ;; Mutable portable session record.  The exported surface is still the
    ;; Scheme-readable datum returned by session->datum.
    (define-record-type <agent-scheme-session>
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
      (handles session-handles set-session-handles!)
      (transcript session-transcript set-session-transcript!)
      (recent-events session-recent-events set-session-recent-events!)
      (snapshots session-snapshots set-session-snapshots!)
      (parent-id session-parent-id)
      (forked-from session-forked-from))

    (define (agent-scheme-make-session-store)
      "Construct an empty portable session store."
      (make-session-store '() 0 0))

    ;; Report whether VALUE is in LIST using equal?.
    (define (member-equal? value list)
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    ;; Validate and return SCOPE.
    (define (normalize-scope scope)
      (if (member-equal? scope agent-scheme-session-scopes)
          scope
          (error "unknown session scope" scope)))

    ;; Return KEY from OPTIONS, or DEFAULT if absent.
    (define (option-ref options key default)
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

    ;; Generate a fresh snapshot id in STORE.
    (define (generated-snapshot-id store)
      (let ((next (+ (store-next-snapshot-number store) 1)))
        (set-store-next-snapshot-number! store next)
        (string->symbol
         (string-append "snapshot-" (number->string next)))))

    ;; Return the session object named ID from STORE, or #f.
    (define (find-session store id)
      (let ((cell (assq id (store-sessions store))))
        (if cell (cdr cell) #f)))

    ;; Add SESSION to STORE unless a durable session with the same id exists.
    (define (store-session! store session)
      (if (not (eq? (session-scope session) 'fresh))
          (begin
            (if (find-session store (session-id session))
                (error "session already exists" (session-id session)))
            (set-store-sessions!
             store
             (cons (cons (session-id session) session)
                   (store-sessions store))))))

    ;; Return SESSION as a Scheme-readable datum.
    (define (session->datum session)
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
        (list 'handles (session-handles session))
        (list 'transcript (session-transcript session))
        (list 'recent-events (session-recent-events session))
        (list 'snapshots
              (map (lambda (snapshot)
                     (cadr (cadr snapshot)))
                   (session-snapshots session))))))

    (define (session-datum-id session-datum)
      "Return the id field from a public SESSION-DATUM."
      (cadr (cadr session-datum)))

    (define (session-create! store scope options)
      "Create a session in STORE for SCOPE using OPTIONS."
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

    (define (session-ref store id)
      "Return a session datum by ID from STORE, or #f."
      (let ((session (find-session store id)))
        (if session (session->datum session) #f)))

    (define (session-list store . maybe-scope)
      "Return session datums from STORE, optionally filtered by SCOPE."
      (let ((scope (if (null? maybe-scope)
                       #f
                       (normalize-scope (car maybe-scope)))))
        (let loop ((sessions (store-sessions store)) (result '()))
          (cond
           ((null? sessions) (reverse result))
           ((or (not scope) (eq? (session-scope (cdar sessions)) scope))
            (loop (cdr sessions)
                  (cons (session->datum (cdar sessions)) result)))
           (else
            (loop (cdr sessions) result))))))

    ;; Return the session object named ID from STORE or raise an error.
    (define (require-session store id)
      (let ((session (find-session store id)))
        (if session
            session
            (error "unknown session" id))))

    ;; Move SESSION to STATUS and return its public datum.
    (define (transition! session status)
      (if (not (member-equal? status agent-scheme-session-states))
          (error "unknown session status" status))
      (set-session-status! session status)
      (session->datum session))

    (define (session-suspend! store id)
      "Suspend session ID in STORE."
      (transition! (require-session store id) 'suspended))

    (define (session-resume! store id)
      "Resume session ID in STORE."
      (transition! (require-session store id) 'active))

    ;; Build a snapshot record for SESSION using SNAPSHOT-ID.
    (define (snapshot-datum session snapshot-id)
      (list 'session-snapshot
            (list 'id snapshot-id)
            (list 'source-session (session-id session))
            (list 'scope (session-scope session))
            (list 'status (session-status session))
            (list 'imports (session-imports session))
            (list 'definitions (session-definitions session))
            (list 'macros (session-macros session))
            (list 'memory (session-memory session))
            (list 'handles (session-handles session))
            (list 'stale-handles '())
            (list 'transcript (session-transcript session))
            (list 'recent-events (session-recent-events session))
            (list 'restores agent-scheme-session-restored-fields)
            (list 'revalidates agent-scheme-session-revalidated-fields)
            (list 'never-restore agent-scheme-session-never-restored-fields)))

    (define (session-snapshot! store id options)
      "Snapshot session ID in STORE using OPTIONS."
      (let* ((session (require-session store id))
             (snapshot-id
              (option-ref options 'id (generated-snapshot-id store)))
             (snapshot (snapshot-datum session snapshot-id)))
        (set-session-snapshots!
         session
         (cons snapshot (session-snapshots session)))
        snapshot))

    (define (session-fork! store id options)
      "Fork session ID in STORE using OPTIONS and return the fork datum."
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
                            (session-handles source)
                            (session-transcript source)
                            (session-recent-events source)
                            '()
                            (session-id source)
                            (session-id source))))
        (store-session! store fork)
        (session->datum fork)))

    (define (session-retire! store id)
      "Retire session ID in STORE and return its datum."
      (let ((session (require-session store id)))
        (set-session-handles! session '())
        (transition! session 'retired)))))
