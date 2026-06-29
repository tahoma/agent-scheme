;;; native-cli.sld --- Host-neutral native CLI process-boundary adapter
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Host/core boundary: this library is the portable, host-neutral half of the
;;; native CLI and daemon process-boundary adapter described in
;;; docs/native-cli-daemon-adapter.md.  It resolves each request's authority
;;; posture from the checked-in fixture, and on approval performs the real host
;;; operation through the one host-specific capability in (cli process-host).
;;;
;;; The interpreted entrypoint (tools/consent-native-cli.scm) and the future
;;; compiled path share these Scheme-readable request, decision, result, event,
;;; audit, and error records; the record vocabulary is the contract.  Every
;;; denial -- noninteractive confirmation, stale or invalid job handle, denied
;;; stdin port -- is decided before `cli-host-run' is ever called, so a denied
;;; request never spawns a child.  Boundary records are returned as data so the
;;; entrypoint can write them to stdout while writing approval prompts to a
;;; separate stream, keeping prompts out of any host-backed stdin port.

(define-library (cli native-cli)
  (export cli-native-cli-execute
          cli-native-cli-parse-arguments
          cli-native-cli-main)
  (import (scheme base)
          (scheme write)
          (scheme read)
          (scheme file)
          (scheme process-context)
          (cli process-host))

  (begin
    ;; Fixed timestamp so emitted records stay deterministic across runs.
    (define cli-native-cli--timestamp "2026-05-21T13:25:00-0700")

    ;; Repository-relative path to the native CLI and daemon adapter fixture,
    ;; read for its authority postures so the interpreted and compiled paths
    ;; share one capability vocabulary.
    (define cli-native-cli--fixture-path
      "fixtures/host-adapters/native-cli-daemon.scm")

    ;; Operation table: subcommand -> (binding library domain operation
    ;; authority).  The adapter never invents authority outside this table; the
    ;; posture for the authority class is resolved from the fixture.
    (define cli-native-cli--operations
      '(("process-run"
         cli-process-start! (cli process) process spawn process-control)
        ("process-status"
         cli-process-status (cli process) process process-status
         process-observation)
        ("process-signal"
         cli-process-signal! (cli process) process signal process-control)
        ("stdin-read"
         cli-standard-input (cli stdio) port read terminal-io)))

    ;;;; Option access

    (define (cli-native-cli--opt options key default)
      "Return the value bound to KEY in OPTIONS, or DEFAULT."
      (let ((entry (assq key options)))
        (if entry (cdr entry) default)))

    (define (cli-native-cli--text value)
      "Return VALUE as a string whether it is already a string or a symbol."
      (if (symbol? value) (symbol->string value) value))

    (define (cli-native-cli--id prefix base)
      "Return a deterministic record id symbol from PREFIX and the BASE symbol."
      (string->symbol (string-append prefix "-" (symbol->string base))))

    ;;;; Fixture navigation (standard reader only)

    (define (cli-native-cli--fields record)
      "Return RECORD's field forms, treating a leading sub-list as a headless"
      "record whose fields start at the car."
      (if (pair? (car record)) record (cdr record)))

    (define (cli-native-cli--field record name)
      "Return the (NAME ...) field of RECORD, or #f."
      (let loop ((fields (cli-native-cli--fields record)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields)) (eq? (caar fields) name)) (car fields))
         (else (loop (cdr fields))))))

    (define (cli-native-cli--field-value record name)
      "Return the single value after RECORD field NAME, or #f."
      (let ((entry (cli-native-cli--field record name)))
        (and entry (cadr entry))))

    (define (cli-native-cli--fixture)
      "Read the adapter fixture datum from the repository."
      (call-with-input-file cli-native-cli--fixture-path read))

    (define (cli-native-cli--policy-for authority)
      "Return the declared policy posture symbol for authority class AUTHORITY."
      (let* ((adapter (cli-native-cli--field-value
                       (cli-native-cli--fixture) 'adapter))
             (entries (cli-native-cli--field-value adapter 'authority)))
        (let loop ((entries entries))
          (cond
           ((null? entries) #f)
           ((eq? (cli-native-cli--field-value (car entries) 'class) authority)
            (cli-native-cli--field-value (car entries) 'policy))
           (else (loop (cdr entries)))))))

    ;;;; Record builders (the Scheme-readable boundary contract)

    (define (cli-native-cli--request options spec resource-term)
      "Build the capability-request datum for OPTIONS, operation SPEC, and"
      "RESOURCE-TERM."
      `(capability-request
        (id ,(string->symbol
              (cli-native-cli--opt options 'request-id "req-native-cli")))
        (session ,(string->symbol
                   (cli-native-cli--opt options 'session "project-main")))
        (adapter native-cli-daemon)
        (library ,(list-ref spec 2))
        (binding ,(list-ref spec 1))
        (domain ,(list-ref spec 3))
        (operation ,(list-ref spec 4))
        (effect ,(list-ref spec 5))
        ,resource-term))

    (define (cli-native-cli--decision id request-id status reason grant)
      "Build the capability-decision datum with ID for REQUEST-ID's STATUS,"
      "REASON, and GRANT (`none' when GRANT is #f)."
      `(capability-decision
        (id ,id) (request ,request-id) (status ,status)
        (grant ,(if grant grant 'none)) (reason ,reason)))

    (define (cli-native-cli--event id session kind source payload)
      "Build the adapter-event datum with ID for SESSION carrying KIND, SOURCE,"
      "and PAYLOAD at the fixed adapter timestamp."
      `(adapter-event
        (id ,id) (adapter native-cli-daemon) (session ,session)
        (kind ,kind) (source ,source) (payload ,payload)
        (timestamp ,cli-native-cli--timestamp)))

    (define (cli-native-cli--result options id value events audit usage)
      "Build the adapter-result datum with ID for OPTIONS carrying VALUE, the"
      "EVENTS and AUDIT id lists, and resource USAGE."
      `(adapter-result
        (id ,id) (adapter native-cli-daemon)
        (mode ,(string->symbol (cli-native-cli--opt options 'mode "cli")))
        (execution ,(string->symbol
                     (cli-native-cli--opt options 'execution "interpreted")))
        (session ,(string->symbol
                   (cli-native-cli--opt options 'session "project-main")))
        (status ok) (value ,value) (events ,events) (audit ,audit)
        (resource-usage ,usage)))

    (define (cli-native-cli--audit id session request-id decision-id result)
      "Build the adapter-audit datum with ID linking SESSION, REQUEST-ID, and"
      "DECISION-ID to RESULT at the fixed adapter timestamp."
      `(adapter-audit
        (id ,id) (adapter native-cli-daemon) (session ,session)
        (request ,request-id) (decision ,decision-id) (result ,result)
        (sink (handle audit-sink h-audit-1)) (redactions ())
        (timestamp ,cli-native-cli--timestamp)))

    (define (cli-native-cli--error kind session request-id decision-id message
                                   irritants handle domain operation condition)
      "Build an adapter-error datum.  HANDLE, DOMAIN, OPERATION, and CONDITION"
      "are appended only when non-#f so a liveness denial can carry the nested"
      "capability-error condition."
      (append
       `(adapter-error
         (kind ,kind) (adapter native-cli-daemon) (session ,session)
         (request ,request-id) (decision ,decision-id) (message ,message)
         (irritants ,irritants))
       (if handle `((handle ,handle)) '())
       (if domain `((domain ,domain)) '())
       (if operation `((operation ,operation)) '())
       (if condition `((condition ,condition)) '())))

    ;;;; Capability decision resolver

    (define (cli-native-cli--resolve options spec)
      "Resolve the decision for OPTIONS against operation SPEC and return an"
      "alist with `status' (`approved' or `denied'), `reason', and optionally"
      "`error-kind', `grant', and `prompt'.  The liveness gate runs first, so a"
      "non-live handle is denied before any prompt posture or host operation."
      (let* ((authority (list-ref spec 5))
             (policy (cli-native-cli--policy-for authority))
             (job-state (cli-native-cli--opt options 'job-state #f))
             (grant (cli-native-cli--opt options 'grant #f))
             (mode (cli-native-cli--opt options 'mode "cli"))
             (deny-noninteractive
              '((status . denied)
                (error-kind . noninteractive-confirmation-unavailable)
                (reason . noninteractive-confirmation-unavailable))))
        (cond
         ((and job-state (not (string=? job-state "live")))
          (let ((kind (if (string=? job-state "stale")
                          'stale-handle 'invalid-handle)))
            `((status . denied) (error-kind . ,kind) (reason . ,kind))))
         ((and grant (memv policy '(confirmation-gated grant-required)))
          `((status . approved) (reason . "covered-by-grant")
            (grant . ,(string->symbol grant))))
         ((memv policy '(allow-or-confirm redaction-gated))
          '((status . approved) (reason . "allowed-by-policy")))
         ((memv policy '(confirmation-gated grant-required))
          (cond
           ((string=? mode "cli")
            (if (cli-native-cli--opt options 'terminal #f)
                '((status . approved) (reason . "approved-terminal-prompt")
                  (prompt . "terminal approval prompt"))
                deny-noninteractive))
           ((string=? mode "batch")
            (if (cli-native-cli--opt options 'approval #f)
                '((status . approved) (reason . "approved-preloaded-decision"))
                deny-noninteractive))
           ((string=? mode "daemon")
            (if (cli-native-cli--opt options 'channel #f)
                '((status . approved) (reason . "approved-daemon-channel")
                  (prompt . "daemon approval request"))
                deny-noninteractive))
           (else deny-noninteractive)))
         (else
          '((status . denied) (error-kind . unsupported-effect)
            (reason . unsupported-effect))))))

    ;;;; Resource and irritant construction

    (define (cli-native-cli--environment-datum entry)
      "Return the (NAME VALUE) datum for an environment grant (NAME . VALUE)."
      (list (string->symbol (car entry)) (cdr entry)))

    (define (cli-native-cli--resource-term options)
      "Build the request resource term from OPTIONS: a command resource with"
      "its arguments, cwd, and environment grants, a process-job handle"
      "resource, or `(resource none)'."
      (let ((command (cli-native-cli--opt options 'command #f))
            (arguments (cli-native-cli--opt options 'child-arguments '()))
            (cwd (cli-native-cli--opt options 'cwd #f))
            (environment (cli-native-cli--opt options 'environment '()))
            (job-id (cli-native-cli--opt options 'job-id #f)))
        (cond
         (command
          (append
           `(resource (command ,command))
           (if (null? arguments) '() `((arguments ,arguments)))
           (if cwd `((cwd ,cwd)) '())
           (if (null? environment)
               '()
               `((environment ,(map cli-native-cli--environment-datum
                                     environment))))))
         (job-id `(resource (handle process-job ,(string->symbol job-id))))
         (else '(resource none)))))

    (define (cli-native-cli--irritants options)
      "Return the error irritants for OPTIONS: the child arguments, a single"
      "command form, or the empty list."
      (let ((arguments (cli-native-cli--opt options 'child-arguments '()))
            (command (cli-native-cli--opt options 'command #f)))
        (cond
         ((not (null? arguments)) arguments)
         (command `((command ,command)))
         (else '()))))

    ;;;; Denial and approval outcomes

    (define (cli-native-cli--deny options spec request decision-id resolution)
      "Return (EXIT RECORDS PROMPTS) for a denied RESOLUTION, proving no host"
      "operation ran by emitting no result and spawning no child."
      (let* ((session (string->symbol
                       (cli-native-cli--opt options 'session "project-main")))
             (request-id (cli-native-cli--field-value request 'id))
             (kind (cli-native-cli--opt resolution 'error-kind 'policy-denied))
             (reason (cli-native-cli--opt resolution 'reason kind))
             (job-id (cli-native-cli--opt options 'job-id #f))
             (handle (and job-id (string->symbol job-id)))
             (liveness (and (memv kind '(stale-handle invalid-handle)) #t))
             (domain (list-ref spec 3))
             (operation (list-ref spec 4))
             (decision (cli-native-cli--decision
                        decision-id request-id 'denied reason #f))
             (error-datum
              (cli-native-cli--error
               kind session request-id decision-id
               (string-append (cli-native-cli--text reason) " denied in "
                              (cli-native-cli--opt options 'mode "cli") " mode")
               (cli-native-cli--irritants options)
               (and liveness handle)
               (and liveness domain)
               (and liveness operation)
               (and liveness
                    `(capability-error (kind ,kind) (handle ,handle)
                                       (domain ,domain)))))
             (audit (cli-native-cli--audit
                     (cli-native-cli--id "audit" request-id)
                     session request-id decision-id `(denied ,reason))))
        (list 3 (list request decision error-datum audit) '())))

    (define (cli-native-cli--stderr-file request-id)
      "Compose the temporary path that backs a request's captured child stderr."
      (string-append
       (or (get-environment-variable "TMPDIR") "/tmp")
       "/consent-native-cli-" (symbol->string request-id) ".stderr"))

    (define (cli-native-cli--run-events request-id session source prompt mode run)
      "Build the streaming events for an approved process-run from the host run"
      "result RUN (EXIT STDOUT STDERR) plus any approval PROMPT."
      (let ((exit (car run)) (stdout (cadr run)) (stderr (list-ref run 2)))
        (append
         (if prompt
             (list (cli-native-cli--event
                    (cli-native-cli--id "event-approval" request-id) session
                    (if (string=? mode "daemon")
                        'approval-request 'approval-decision)
                    source prompt))
             '())
         (if (> (string-length stdout) 0)
             (list (cli-native-cli--event
                    (cli-native-cli--id "event-out" request-id) session
                    'stdout source stdout))
             '())
         (if (> (string-length stderr) 0)
             (list (cli-native-cli--event
                    (cli-native-cli--id "event-err" request-id) session
                    'stderr source stderr))
             '())
         (list (cli-native-cli--event
                (cli-native-cli--id "event-exit" request-id) session
                'process-exit source `(exit-status ,exit))))))

    (define (cli-native-cli--approve options spec request decision-id resolution)
      "Return (EXIT RECORDS PROMPTS) for an approved request, performing the"
      "real host operation for SPEC's subcommand."
      (let* ((subcommand (cli-native-cli--opt options 'subcommand #f))
             (session (string->symbol
                       (cli-native-cli--opt options 'session "project-main")))
             (request-id (cli-native-cli--field-value request 'id))
             (grant (cli-native-cli--opt resolution 'grant #f))
             (prompt (cli-native-cli--opt resolution 'prompt #f))
             (mode (cli-native-cli--opt options 'mode "cli"))
             (decision (cli-native-cli--decision
                        decision-id request-id 'approved
                        (cli-native-cli--opt resolution 'reason "approved")
                        grant))
             (job (string->symbol
                   (or (cli-native-cli--opt options 'job-id #f) "h-job-1")))
             (source `(handle process-job ,job))
             (usage '((host-calls 1)))
             (audit-id (cli-native-cli--id "audit" request-id))
             (events '())
             (value source))
        (cond
         ((string=? subcommand "process-run")
          (let ((run (cli-host-run
                      (cli-native-cli--opt options 'command #f)
                      (cli-native-cli--opt options 'child-arguments '())
                      (cli-native-cli--opt options 'stdin-file #f)
                      (cli-native-cli--stderr-file request-id)
                      (cli-native-cli--opt options 'cwd #f)
                      (cli-native-cli--opt options 'environment '()))))
            (set! events (cli-native-cli--run-events
                          request-id session source prompt mode run))))
         ((string=? subcommand "process-signal")
          (let* ((signal-name (cli-native-cli--opt options 'signal "TERM"))
                 ;; Background a child, signal it, and reap it: the reaped status
                 ;; (128 + signal number) is a real signal-terminated exit.  The
                 ;; shell's job-control note is not surfaced as a stdout event.
                 (run (cli-host-run
                       "/bin/sh"
                       (list "-c"
                             (string-append "sleep 30 & __ct=$! ; kill -s "
                                            signal-name
                                            " $__ct ; wait $__ct"))
                       #f #f #f '())))
            (set! events
                  (list (cli-native-cli--event
                         (cli-native-cli--id "event-exit" request-id) session
                         'process-exit source
                         `((signal ,(string->symbol signal-name))
                           (exit-status ,(car run))))))))
         ((string=? subcommand "stdin-read")
          (set! value `(handle stdio-port ,job)))
         (else #f))
        (let* ((event-ids (map (lambda (event)
                                 (cli-native-cli--field-value event 'id))
                               events))
               (result (cli-native-cli--result
                        options (cli-native-cli--id "result" request-id)
                        value event-ids (list audit-id) usage))
               (audit (cli-native-cli--audit
                       audit-id session request-id decision-id
                       `(ok ,value))))
          (list 0
                (append (list request decision) events (list result audit))
                (if prompt (list prompt) '())))))

    ;;;; Execution and entry point

    (define (cli-native-cli-execute options)
      "Execute the request described by OPTIONS and return"
      "(EXIT RECORDS PROMPTS).  RECORDS is the Scheme-readable boundary record"
      "stream; PROMPTS is the list of approval prompt summaries that belong on"
      "the diagnostic stream, never on the record stream or a host-backed stdin"
      "port.  Performs the real host operation through (cli process-host) only"
      "after the request is approved."
      #((parameters
         (options
          (type list)
          (description
           ("Parsed options alist naming the subcommand, mode, session,"
             "resource, and gate inputs for the request."))))
        (returns
         (type list)
         (description
          ("A `(EXIT RECORDS PROMPTS)' list whose RECORDS are"
            "Scheme-readable boundary records and PROMPTS are"
            "diagnostic-stream approval summaries.")))
        (effects state-read host-eval allocation error))
      (let ((subcommand (cli-native-cli--opt options 'subcommand #f)))
        (unless subcommand
          (error "Usage: consent-native-cli OPERATION [OPTIONS]"))
        (let ((spec (assoc subcommand cli-native-cli--operations)))
          (unless spec
            (error "Unknown native CLI operation" subcommand))
          (let* ((resource-term (cli-native-cli--resource-term options))
                 (request (cli-native-cli--request options spec resource-term))
                 (request-id (cli-native-cli--field-value request 'id))
                 (decision-id (cli-native-cli--id "dec" request-id))
                 (resolution (cli-native-cli--resolve options spec)))
            (if (eq? (cli-native-cli--opt resolution 'status 'denied) 'approved)
                (cli-native-cli--approve options spec request decision-id
                                         resolution)
                (cli-native-cli--deny options spec request decision-id
                                      resolution))))))

    (define (cli-native-cli--environment-pair assignment)
      "Split a NAME=VALUE assignment into the (NAME . VALUE) pair the host shim"
      "expects; a bare NAME maps to an empty value."
      (let loop ((index 0))
        (cond
         ((>= index (string-length assignment)) (cons assignment ""))
         ((char=? (string-ref assignment index) #\=)
          (cons (substring assignment 0 index)
                (substring assignment (+ index 1) (string-length assignment))))
         (else (loop (+ index 1))))))

    (define (cli-native-cli-parse-arguments arguments)
      "Parse ARGUMENTS (a list of strings) into the options alist consumed by"
      "`cli-native-cli-execute'.  Leading \"--\" separators are ignored so a"
      "host can pass a clean argument vector after its own option processing."
      #((parameters
         (arguments
          (type string)
          (description
           ("List of command-line argument strings: a leading"
             "subcommand followed by recognized flags and their values."))))
        (returns
         (type list)
         (description
          ("An options alist consumed by `cli-native-cli-execute',"
            "defaults seeded and flag overrides consed to the front.")))
        (effects allocation error))
      (let ((cleaned (let drop ((items arguments))
                       (if (and (pair? items) (string=? (car items) "--"))
                           (drop (cdr items))
                           items))))
        (let loop ((items (if (pair? cleaned) (cdr cleaned) '()))
                   (options
                    (list (cons 'subcommand
                                (if (pair? cleaned) (car cleaned) #f))
                          (cons 'mode "cli")
                          (cons 'execution "interpreted")
                          (cons 'session "project-main")
                          (cons 'child-arguments '())
                          (cons 'environment '()))))
          (define (put key value rest)
            (loop rest (cons (cons key value) options)))
          (define (append-to key value rest)
            (loop rest
                  (cons (cons key
                              (append (cli-native-cli--opt options key '())
                                      (list value)))
                        options)))
          ;; Newer bindings are consed to the front, and `cli-native-cli--opt'
          ;; reads the first match, so a flag overrides its default in place.
          (if (null? items)
              options
              (let ((flag (car items)))
                (cond
                 ((string=? flag "--mode") (put 'mode (cadr items) (cddr items)))
                 ((string=? flag "--execution")
                  (put 'execution (cadr items) (cddr items)))
                 ((string=? flag "--session")
                  (put 'session (cadr items) (cddr items)))
                 ((string=? flag "--request-id")
                  (put 'request-id (cadr items) (cddr items)))
                 ((string=? flag "--command")
                  (put 'command (cadr items) (cddr items)))
                 ((string=? flag "--arg")
                  (append-to 'child-arguments (cadr items) (cddr items)))
                 ((string=? flag "--stdin-file")
                  (put 'stdin-file (cadr items) (cddr items)))
                 ((string=? flag "--job-id")
                  (put 'job-id (cadr items) (cddr items)))
                 ((string=? flag "--job-state")
                  (put 'job-state (cadr items) (cddr items)))
                 ((string=? flag "--signal")
                  (put 'signal (cadr items) (cddr items)))
                 ((string=? flag "--grant")
                  (put 'grant (cadr items) (cddr items)))
                 ((string=? flag "--cwd")
                  (put 'cwd (cadr items) (cddr items)))
                 ((string=? flag "--env")
                  (append-to 'environment
                             (cli-native-cli--environment-pair (cadr items))
                             (cddr items)))
                 ((string=? flag "--terminal") (put 'terminal #t (cdr items)))
                 ((string=? flag "--channel") (put 'channel #t (cdr items)))
                 ((string=? flag "--approval") (put 'approval #t (cdr items)))
                 (else (error "Unknown native CLI flag" flag))))))))

    (define (cli-native-cli-main)
      "Entry point for the native CLI process-boundary program."
      "Parse the command line, execute the request, write the Scheme-readable"
      "record stream to stdout and any approval prompt to the diagnostic"
      "stream, then exit with the adapter's exit code."
      #((parameters)
        (returns
         . ("Does not return normally; terminates the process with the"
            "adapter's exit code via `exit'."))
        (effects state-read state-write host-eval allocation error))
      (let* ((options (cli-native-cli-parse-arguments (cdr (command-line))))
             (outcome (cli-native-cli-execute options))
             (exit-code (car outcome))
             (records (cadr outcome))
             (prompts (list-ref outcome 2)))
        (for-each (lambda (prompt)
                    (display "consent-native-cli: approval: "
                             (current-error-port))
                    (display prompt (current-error-port))
                    (newline (current-error-port)))
                  prompts)
        (for-each (lambda (record) (write record) (newline)) records)
        (exit exit-code)))))
