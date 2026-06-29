;;; repl-shell.sld --- Portable terminal REPL shell over the interaction contract
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Host/core boundary: this library is the portable, host-neutral half of the
;;; terminal REPL shell (docs/portable-repl.md).  It implements the host-neutral
;;; obligations of the cross-host REPL interaction contract
;;; (docs/repl-interaction-contract.md) on the portable R7RS runtime: incremental
;;; one-form-at-a-time reading, evaluation in a durable session interaction
;;; environment, and emission of the contract's Scheme-readable record vocabulary
;;; (`repl-prompt', `repl-submission', `repl-result', `repl-condition',
;;; `repl-exit').
;;;
;;; The loop is a driver over the substrate, not new runtime mechanism.  Durable
;;; session evaluation is `(consent eval)' `consent-interaction-eval-form' over a
;;; `consent-make-interaction-context'; values, results, and conditions are the
;;; existing `(consent result)' datums; reading is the shared `(consent reader)'.
;;; The driver consumes only interaction input; evaluated forms write their own
;;; output to the program ports, so a scripted consumer of program stdout is
;;; never corrupted by prompts, results, or diagnostics.
;;;
;;; `cli-repl-drive' is a pure function from an interaction-input chunk source to
;;; the list of contract records, so the cross-host conformance corpus (#392) and
;;; the portable smoke tests can assert the emitted record stream without a TTY.
;;; `cli-repl-main' wires that driver to stdin and the diagnostic stream for an
;;; interactive or piped terminal session.
;;;
;;; The raw record stream is the canonical surface; everyday human output is a
;;; *chrome* over it (`--chrome NAME', default `comment') supplied by the
;;; host-neutral (cli repl-chrome) layer.  `cli-repl-main' selects the chrome,
;;; resolves `--color=auto|always|never' against the control channel's terminal
;;; status and NO_COLOR, applies the chrome to each record, and flushes the
;;; control channel so a no-newline prompt appears before the blocking read.  It
;;; also decides from stdin's terminal status whether the interaction input is
;;; already echoed -- an interactive TTY echoes each typed form in cooked mode --
;;; so the `comment' chrome suppresses its own submission echo and a captured
;;; transcript keeps exactly one replayable copy of each form.  Chrome text stays
;;; on the control channel (stderr).  Program output follows a per-chrome policy:
;;; the replayable `comment' chrome OWNS it, rendering each chunk as a commented
;;; (`;;   :: ') line on the control channel so a captured transcript replays the
;;; output too, leaving stdout clean; every other chrome
;;; (`classic'/`quiet'/`silent'/`datum') leaves program output raw on stdout.  So
;;; a consumer that wants raw program output on stdout selects one of those (or
;;; `--chrome silent' for output alone).  `--chrome datum' recovers the canonical
;;; record stream and is always reachable.
;;;
;;; Transcript capture and replay (docs/repl-interaction-contract.md, "Capture
;;; and Replay") build on that canonical surface.  The `datum' chrome stream is
;;; the capture format: one contract record datum per line, written by the
;;; consent writer and reloadable with the standard reader.
;;; `cli-repl-records-from-datum-stream' reloads a captured stream into records;
;;; `cli-repl-submissions-from-records' extracts the complete submissions, which
;;; `cli-repl-replay-records' re-feeds to a FRESH session, so a transcript
;;; doubles as a reproducible bug report and a fixture capture.  Replay
;;; reproduces submissions, ordering, and deterministic results/conditions, but
;;; NOT live host effects: a replay session carries only the authority it is
;;; granted, so an effect that succeeded under the captured authority fails
;;; closed under a weaker replay posture -- surfaced as a `repl-condition', not
;;; the recorded value.  `cli-repl-replay-report' compares the captured and
;;; replayed per-submission outcomes and reports any such divergence rather than
;;; letting it pass silently; the `--replay FILE' terminal mode emits the
;;; replayed stream and that report and exits non-zero on divergence.

(define-library (cli repl-shell)
  (export cli-repl-drive
          cli-repl-records-from-string
          cli-repl-records-from-datum-stream
          cli-repl-submissions-from-records
          cli-repl-replay-input
          cli-repl-replay-records
          cli-repl-replay-report
          cli-repl-run
          cli-repl-parse-options
          cli-repl-rendered-from-string
          cli-repl-capture-from-string
          cli-repl-replay-main
          cli-repl-main)
  (import (scheme base)
          (scheme write)
          (scheme read)
          (scheme file)
          (scheme process-context)
          (consent eval)
          (consent reader)
          (consent result)
          (only (consent library) consent-apply-callable)
          (cli repl-chrome))

  ;; The one host-specific obligation of the chrome layer: deciding whether a
  ;; given port is a terminal.  The control channel (stderr) drives `--color=auto'
  ;; -- ANSI off when the session is piped or redirected -- and the interaction
  ;; input (stdin) drives the `comment' chrome's echo decision -- suppress the
  ;; submission echo when the terminal already echoes typed forms.  R7RS-small
  ;; has no portable terminal-port predicate, so each host branch imports its
  ;; own; hosts without one fall to the `else' branch, where a port is treated as
  ;; non-terminal (color off, echo kept).
  (cond-expand
   (gambit
    (import (only (gambit) tty?))
    (begin
      (define (repl--port-tty? port) (and (tty? port) #t))))
   (racket
    (import (only (racket base) terminal-port?))
    (begin
      (define (repl--port-tty? port) (and (terminal-port? port) #t))))
   (guile
    (import (only (guile) isatty?))
    (begin
      (define (repl--port-tty? port) (and (isatty? port) #t))))
   (gauche
    (import (gauche base))
    (begin
      (define (repl--port-tty? port) (and (sys-isatty port) #t))))
   (else
    (begin
      (define (repl--port-tty? port) (and port #f)))))

  (begin

    ;;;; Small string helpers (kept R7RS-portable; no SRFI dependencies)

    (define (repl--whitespace? char)
      "Return #t when CHAR is intertoken whitespace for trimming purposes."
      (or (char=? char #\space)
          (char=? char #\newline)
          (char=? char #\tab)
          (char=? char #\return)))

    (define (repl--blank? string)
      "Return #t when STRING is empty or contains only whitespace."
      (let ((length (string-length string)))
        (let loop ((index 0))
          (cond
           ((>= index length) #t)
           ((repl--whitespace? (string-ref string index)) (loop (+ index 1)))
           (else #f)))))

    (define (repl--trim string)
      "Return STRING without leading or trailing whitespace."
      (let ((length (string-length string)))
        (let find-start ((start 0))
          (cond
           ((>= start length) "")
           ((repl--whitespace? (string-ref string start)) (find-start (+ start 1)))
           (else
            (let find-end ((end length))
              (if (repl--whitespace? (string-ref string (- end 1)))
                  (find-end (- end 1))
                  (substring string start end))))))))

    (define (repl--horizontal-whitespace? char)
      "Return #t when CHAR is space or tab (horizontal whitespace, not a line break)."
      (or (char=? char #\space)
          (char=? char #\tab)))

    (define (repl--submission-boundary buffer next)
      "Return the index in BUFFER where program input begins after a form"
      "ending at NEXT.  Skip horizontal whitespace after the form; if a newline"
      "follows, consume exactly that newline as the submission terminator (the"
      "Enter that submits a line is not program data), so program input begins"
      "on the next line.  Otherwise the boundary is NEXT and any same-line"
      "trailing text is program input for an evaluated read."
      (let ((length (string-length buffer)))
        (let loop ((index next))
          (cond
           ((>= index length) next)
           ((repl--horizontal-whitespace? (string-ref buffer index))
            (loop (+ index 1)))
           ((char=? (string-ref buffer index) #\newline) (+ index 1))
           (else next)))))

    ;;;; Interaction-input chunk sources

    (define (repl--list-chunk-source chunks)
      "Return a chunk source thunk yielding each newline-kept string in CHUNKS then EOF."
      (let ((remaining chunks))
        (lambda ()
          (if (null? remaining)
              (eof-object)
              (let ((chunk (car remaining)))
                (set! remaining (cdr remaining))
                chunk)))))

    (define (repl--split-lines string)
      "Split STRING into newline-terminated chunks, preserving each newline."
      (let ((length (string-length string)))
        (let loop ((start 0) (index 0) (chunks '()))
          (cond
           ((>= index length)
            (reverse (if (> index start)
                         (cons (substring string start index) chunks)
                         chunks)))
           ((char=? (string-ref string index) #\newline)
            (loop (+ index 1)
                  (+ index 1)
                  (cons (substring string start (+ index 1)) chunks)))
           (else (loop start (+ index 1) chunks))))))

    ;;;; Contract record constructors

    (define (repl--tag prefix ordinal)
      "Return a record-id symbol such as `sub-3' for PREFIX and ORDINAL."
      (string->symbol
       (string-append prefix "-" (number->string ordinal))))

    (define (repl--session-field session)
      "Return SESSION rendered as a symbol for a contract record field."
      (if (symbol? session)
          session
          (string->symbol session)))

    ;; Contract records are consent data: numeric fields embed canonical
    ;; number records (matching the Emacs twin's consent-repl-stream--int)
    ;; so the record stream renders through the consent writer.
    (define (repl--prompt-record session ordinal state pending
                                 . maybe-pending-stack)
      "Build a `repl-prompt' record for SESSION at ORDINAL with STATE and"
      "PENDING.  A continuation prompt additionally carries the reader's"
      "pending-nesting indicator, derived from the optional open-construct"
      "stack of the incomplete read (innermost first): `nesting' is the"
      "open-construct count and `pending-kind' the innermost construct kind,"
      "or the symbol `datum' when a datum prefix is pending with no construct"
      "open."
      (let ((stack (if (and (pair? maybe-pending-stack)
                            (pair? (car maybe-pending-stack)))
                       (car maybe-pending-stack)
                       '())))
        (append
         (list 'repl-prompt
               (list 'session (repl--session-field session))
               (list 'ordinal (consent-make-canonical-integer ordinal))
               (list 'state state)
               (list 'pending pending))
         (if (eq? state 'continuation)
             (list (list 'nesting
                         (consent-make-canonical-integer (length stack)))
                   (list 'pending-kind
                         (if (pair? stack) (car stack) 'datum)))
             '()))))

    (define (repl--submission-record session ordinal source complete eof)
      "Build a `repl-submission' record for the SOURCE read at ORDINAL in SESSION."
      (list 'repl-submission
            (list 'id (repl--tag "sub" ordinal))
            (list 'session (repl--session-field session))
            (list 'ordinal (consent-make-canonical-integer ordinal))
            (list 'source source)
            (list 'complete complete)
            (list 'eof eof)))

    (define (repl--result-record session ordinal evaluation-result display)
      "Build a `repl-result' record wrapping EVALUATION-RESULT and DISPLAY at"
      "ORDINAL.  The `ordinal' field mirrors `repl-prompt' so a pure chrome can"
      "right-align the result marker to the prompt-gutter width without"
      "coupling to the `submission' id format."
      (list 'repl-result
            (list 'id (repl--tag "res" ordinal))
            (list 'submission (repl--tag "sub" ordinal))
            (list 'session (repl--session-field session))
            (list 'ordinal (consent-make-canonical-integer ordinal))
            (list 'evaluation-result evaluation-result)
            (list 'display display)))

    (define (repl--condition-record session ordinal phase recoverable
                                    condition display)
      "Build a `repl-condition' record for PHASE/RECOVERABLE CONDITION at"
      "ORDINAL.  The `ordinal' field mirrors `repl-prompt' so a pure chrome can"
      "right-align the condition marker to the prompt-gutter width."
      (list 'repl-condition
            (list 'id (repl--tag "cond" ordinal))
            (list 'submission (repl--tag "sub" ordinal))
            (list 'session (repl--session-field session))
            (list 'ordinal (consent-make-canonical-integer ordinal))
            (list 'phase phase)
            (list 'recoverable recoverable)
            (list 'condition condition)
            (list 'display display)))

    (define (repl--exit-record session reason status count detail)
      "Build a `repl-exit' record closing SESSION with REASON, STATUS, COUNT, DETAIL."
      (list 'repl-exit
            (list 'session (repl--session-field session))
            (list 'reason reason)
            (list 'status status)
            (list 'count (consent-make-canonical-integer count))
            (list 'detail detail)))

    ;;;; Bounded result rendering (#508)

    ;; Default depth/length/size ceiling `repl--result-display' applies to the
    ;; `repl-result' `display' field; a `render-limits' evaluator option overrides
    ;; it.  `consent-datum->external-bounded' documents the bounding semantics,
    ;; and the Emacs twin mirrors these defaults in
    ;; `consent-repl-stream-default-render-limits'.
    (define cli-repl-default-render-limits
      '((depth . 8) (length . 64) (size . 4096)))

    (define (repl--render-limits options)
      "Return the render-limits alist from OPTIONS, or the documented default."
      (let ((entry (assq 'render-limits options)))
        (if entry (cdr entry) cli-repl-default-render-limits)))

    ;;;; Evaluation-result inspection

    (define (repl--field datum name)
      "Return the single value of field NAME in tagged list DATUM, or #f."
      (let ((entry (assq name (cdr datum))))
        (and entry (pair? (cdr entry)) (cadr entry))))

    (define (repl--error-result? evaluation-result)
      "Return #t when EVALUATION-RESULT carries an error status."
      (eq? (repl--field evaluation-result 'status) 'error))

    (define (repl--result-display evaluation-result limits)
      "Return a human-readable display string for a non-error EVALUATION-RESULT,"
      "bounded by LIMITS so a deep, long, or cyclic value renders in bounded"
      "time and space with the `...' truncation marker (#508)."
      (let ((status (repl--field evaluation-result 'status)))
        (cond
         ((eq? status 'values)
          (let ((entry (assq 'values (cdr evaluation-result))))
            (consent-datum->external-bounded (cons 'values (cadr entry)) limits)))
         (else
          (let ((value (repl--field evaluation-result 'value)))
            (consent-datum->external-bounded value limits))))))

    (define (repl--error-condition evaluation-result)
      "Return the debugger-condition datum from an error EVALUATION-RESULT"
      "for wrapping in the contract condition field."
      (let ((error-entry (assq 'error (cdr evaluation-result))))
        (if (and error-entry (assq 'condition (cdr error-entry)))
            (cadr (assq 'condition (cdr error-entry)))
            (list 'condition (list 'type 'evaluation-error)))))

    (define (repl--error-message evaluation-result)
      "Return the host message string for an error EVALUATION-RESULT."
      (let ((error-entry (assq 'error (cdr evaluation-result))))
        (let ((message-entry (and error-entry
                                  (assq 'message (cdr error-entry)))))
          (if message-entry (cadr message-entry) "evaluation error"))))

    (define (repl--read-condition message)
      "Build a debugger-condition datum for a reader error MESSAGE, shaped"
      "like an evaluator condition."
      (list 'condition
            (list 'type 'reader-error)
            (list 'message message)
            (list 'phase 'read)))

    ;;;; Explicit-exit recognition

    (define (repl--exit-form? datum)
      "Return #t when reader DATUM is a process-context exit/emergency-exit call."
      (let ((stripped (strip-identifiers datum)))
        (and (pair? stripped)
             (memq (car stripped) '(exit emergency-exit))
             #t)))

    (define (repl--exit-disposition datum)
      "Return (cons STATUS DETAIL) for an exit DATUM per the close-status rules."
      (let ((stripped (strip-identifiers datum)))
        (if (or (null? (cdr stripped)) (not (pair? (cdr stripped))))
            (cons 'closed-ok #f)
            (let* ((object (cadr stripped))
                   (rendered (consent-value->external object)))
              (if (or (string=? rendered "#t") (string=? rendered "0"))
                  (cons 'closed-ok #f)
                  (cons 'closed-error rendered))))))

    ;;;; Incremental reading

    (define (repl--diagnostic-message diagnostic)
      "Return the human-readable message carried by recovery DIAGNOSTIC."
      (or (and diagnostic (repl--field diagnostic 'message))
          "reader error"))

    (define (repl--try-read buffer)
      "Read one datum from BUFFER at position 0 over the recovery-aware reader."
      "Return (empty), (complete DATUM NEXT), (incomplete PENDING), or"
      "(malformed MESSAGE).  An incomplete read carries the reader's"
      "open-construct stack so the continuation prompt can render nesting"
      "depth, mirroring the Emacs twin's recovery-step read path."
      (let* ((step (consent-read-recover-from-string-at buffer 0))
             (status (consent-recovery-step-status step)))
        (cond
         ((eq? status 'datum)
          (list 'complete
                (consent-recovery-step-datum step)
                (consent-recovery-step-next step)))
         ((eq? status 'eof)
          (list 'empty))
         ((eq? status 'incomplete)
          (list 'incomplete (consent-recovery-step-pending step)))
         (else
          (list 'malformed
                (repl--diagnostic-message
                 (consent-recovery-step-diagnostic step)))))))

    ;;;; The interaction loop

    (define (repl--callable callback)
      "Return CALLBACK as a directly applicable host procedure."
      "A self-hosted caller (consent --host-run) passes interpreted closures as"
      "engine callbacks; consent-apply-callable runs those in the calling"
      "program's context while host procedures pass through untouched."
      (if (procedure? callback)
          callback
          (lambda arguments (consent-apply-callable callback arguments))))

    ;; The session's program input is the same physical stdin the form reader
    ;; draws from, shared as one cursor.  A REPL session is consented by
    ;; invocation -- the caller handed it this stdin -- so program input is
    ;; authorized by default with this `port'/`read' grant backed by `stdin'
    ;; (ambient effects still gate separately).
    (define repl--program-input-grant
      '(capability-grant (id program-input) (domain port)
                         (operations read close) (scope (backing stdin))
                         (expires never)))

    (define (repl--option-value options key default)
      "Return the value of OPTIONS entry KEY (a (key . values) pair), or DEFAULT."
      (let ((entry (assq key options)))
        (if entry (cdr entry) default)))

    (define (repl--interaction-options session-id read-chunk options)
      "Augment REPL OPTIONS with the session id, a program-input reader over"
      "READ-CHUNK, and the consent-by-invocation stdin grant, so the"
      "interaction context shares one stdin cursor between the form reader and"
      "evaluated reads.  Any grants already in OPTIONS are preserved by merging"
      "into the first capability-grants entry."
      (let ((reader (lambda ()
                      (let ((chunk (read-chunk)))
                        (if (eof-object? chunk) #f chunk))))
            (grants (cons repl--program-input-grant
                          (repl--option-value options 'capability-grants '()))))
        (cons (cons 'session-id session-id)
              (cons (cons 'program-input-reader reader)
                    (cons (cons 'capability-grants grants)
                          options)))))

    (define (repl--engine read-chunk emit-record emit-output session options)
      "Run the host-neutral loop: read from READ-CHUNK, send records to"
      "EMIT-RECORD and program output to EMIT-OUTPUT under SESSION/OPTIONS,"
      "returning the close-status exit code."
      (let* ((read-chunk (repl--callable read-chunk))
             (emit-record (repl--callable emit-record))
             (emit-output (repl--callable emit-output))
             (session-id (if (symbol? session)
                             (symbol->string session)
                             session))
             ;; The live session manager owns one interaction context per
             ;; session.  Seeding installs the initial default session and a
             ;; factory that shares a single stdin cursor across sessions, so a
             ;; `switch-session'/`create-session' verb run in one form redirects
             ;; the next form to the now-current session's sandbox environment.
             (manager (consent-repl-session-manager))
             ;; The depth/length/size ceiling applied to each result `display'
             ;; (#508); a `render-limits' option overrides the documented default.
             (render-limits (repl--render-limits options))
             (exit-code 0))
        (define (current-interaction)
          (consent-session-manager-current-context manager))
        (define (emit record)
          (when (and (pair? record) (eq? (car record) 'repl-exit))
            (set! exit-code
                  (if (eq? (repl--field record 'status) 'closed-error) 1 0)))
          (emit-record record))
        (define (drain-output! interaction)
          (let ((output (consent-interaction-program-output interaction)))
            (when (> (string-length output) 0)
              (emit-output output))))
        (define (acquire buffer ordinal)
          "Acquire one complete form, returning (values KIND PAYLOAD"
          "BUFFER) for KIND complete/malformed/eof/eof-incomplete."
          (let ((outcome (repl--try-read buffer)))
            (cond
             ((eq? (car outcome) 'complete)
              (values 'complete (cdr outcome) buffer))
             ((eq? (car outcome) 'malformed)
              (values 'malformed (cadr outcome) buffer))
             ((eq? (car outcome) 'empty)
              (let ((chunk (read-chunk)))
                (if (eof-object? chunk)
                    (values 'eof #f buffer)
                    (acquire (string-append buffer chunk) ordinal))))
             (else                       ; incomplete
              ;; A partial form is buffered, so the continuation gutter is a
              ;; request for more input: emit (and flush) it *before* the
              ;; blocking read that supplies the continued line.  On a live TTY
              ;; the prompt must front the input the user is about to type;
              ;; emitting it after the read glues the gutter to the next result
              ;; line instead (#448).  Reaching this branch always means a
              ;; partial form is buffered, so the prompt is always warranted --
              ;; including before an EOF-mid-form, where the gutter was shown and
              ;; the user then hit Ctrl-D.
              (emit (repl--prompt-record session ordinal 'continuation #t
                                         (cadr outcome)))
              (let ((chunk (read-chunk)))
                (if (eof-object? chunk)
                    (if (repl--blank? buffer)
                        (values 'eof #f buffer)
                        (values 'eof-incomplete buffer buffer))
                    (acquire (string-append buffer chunk) ordinal)))))))
        (define (skip-to-boundary buffer)
          "Return BUFFER past the next newline so a malformed datum does"
          "not wedge the session."
          (let ((length (string-length buffer)))
            (let loop ((index 0))
              (cond
               ((>= index length) "")
               ((char=? (string-ref buffer index) #\newline)
                (substring buffer (+ index 1) length))
               (else (loop (+ index 1)))))))
        ;; Install the initial default session before the first prompt, so the
        ;; first form already evaluates in a managed session and verbs can
        ;; switch the default for subsequent forms.
        (consent-repl-seed-initial-session!
         manager
         session-id
         (repl--interaction-options session-id read-chunk options))
        (let loop ((buffer "") (ordinal 1) (count 0))
          (emit (repl--prompt-record session ordinal 'ready #f))
          (call-with-values
           (lambda () (acquire buffer ordinal))
           (lambda (kind payload current)
             (cond
              ((eq? kind 'eof)
               (emit (repl--exit-record session 'eof 'closed-ok count #f)))
              ((eq? kind 'eof-incomplete)
               (let ((source (repl--trim payload)))
                 (emit (repl--submission-record session ordinal source #f #t))
                 (emit (repl--condition-record
                        session ordinal 'read #f
                        (repl--read-condition "unterminated form at end of input")
                        "unterminated form at end of input"))
                 (emit (repl--exit-record
                        session 'eof 'closed-error count
                        "unterminated form at end of input"))))
              ((eq? kind 'malformed)
               (emit (repl--condition-record
                      session ordinal 'read #t
                      (repl--read-condition payload)
                      payload))
               (loop (skip-to-boundary current) (+ ordinal 1) count))
              (else                       ; complete
               (let* ((datum (car payload))
                      (next (cadr payload))
                      (source (repl--trim (substring current 0 next)))
                      (boundary (repl--submission-boundary current next))
                      ;; Everything after the submission's terminating newline is
                      ;; this turn's program input, shared on the one stdin cursor.
                      (program-input
                       (substring current boundary (string-length current))))
                 (cond
                  ((repl--exit-form? datum)
                   (emit (repl--submission-record session ordinal source #t #f))
                   (let ((disposition (repl--exit-disposition datum)))
                     (emit (repl--exit-record session 'explicit
                                              (car disposition)
                                              (+ count 1)
                                              (cdr disposition)))))
                  (else
                   (emit (repl--submission-record session ordinal source #t #f))
                   ;; Resolve the session this form runs in *now*: a prior form's
                   ;; `switch-session'/`create-session' may have changed the
                   ;; manager's default, redirecting this turn to a different
                   ;; sandbox environment.  All sessions share one stdin cursor.
                   (let ((interaction (current-interaction)))
                     ;; Seed the shared cursor so an evaluated read consumes the
                     ;; input after this form; whatever it leaves unread is threaded
                     ;; back as the next form-reading buffer, so neither reader steals
                     ;; the other's characters.
                     (consent-interaction-seed-program-input! interaction
                                                              program-input)
                     (let ((result (consent-interaction-eval-form
                                    interaction datum)))
                       ;; Drain this turn's program output before the result
                       ;; record, binding the ordinal so the `comment' chrome's
                       ;; output formatter aligns its `;;   :: ' gutter to this
                       ;; turn's result marker.  Drain the just-evaluated
                       ;; interaction even if the form switched the default.
                       (parameterize ((cli-repl-chrome-output-ordinal ordinal))
                         (drain-output! interaction))
                       (if (repl--error-result? result)
                           (emit (repl--condition-record
                                  session ordinal 'eval #t
                                  (repl--error-condition result)
                                  (repl--error-message result)))
                           (emit (repl--result-record
                                  session ordinal result
                                  (repl--result-display result render-limits))))
                       (loop (or (consent-interaction-program-input-remainder
                                  interaction)
                                 program-input)
                             (+ ordinal 1) (+ count 1))))))))))))
        exit-code))

    (define (cli-repl-run read-chunk write-record write-output session
                          . maybe-options)
      "Run a REPL session, streaming records to WRITE-RECORD and program"
      "output to WRITE-OUTPUT on separate streams, returning the"
      "close-status exit code."
      #((parameters
         (read-chunk (type string)
          (description
           ("Chunk source thunk yielding the next newline-kept"
             "interaction-input string or EOF.")))
         (write-record (type procedure)
          (description ("Procedure receiving each emitted contract record datum.")))
         (write-output (type procedure)
          (description ("Procedure receiving each drained program-output string.")))
         (session (type symbol)
          (description ("Session identifier symbol or string for the record stream.")))
         (maybe-options (type list)
          (description
           ("Optional single-element list holding the REPL option"
             "alist."))))
        (returns
         . ("The close-status exit code: 0 on clean close, 1 on error"
            "close."))
        (effects host-eval state-write error allocation))
      (repl--engine read-chunk write-record write-output session
                    (if (null? maybe-options) '() (car maybe-options))))

    (define (cli-repl-drive read-chunk session . maybe-options)
      "Drive a REPL session over READ-CHUNK and return the ordered contract"
      "records, discarding program output."
      #((parameters
         (read-chunk (type procedure)
          (description
           ("Chunk source thunk yielding the next interaction-input"
             "string or EOF.")))
         (session (type (or symbol string))
          (description ("Session identifier symbol or string for the record stream.")))
         (maybe-options (type list)
          (description
           ("Optional single-element list holding the REPL option"
             "alist."))))
        (returns (type list)
         (description "The ordered list of emitted contract record datums."))
        (effects host-eval allocation error))
      (let ((records '()))
        (repl--engine read-chunk
                      (lambda (record) (set! records (cons record records)))
                      (lambda (output) output)
                      session
                      (if (null? maybe-options) '() (car maybe-options)))
        (reverse records)))

    (define (cli-repl-records-from-string input session . maybe-options)
      "Drive a REPL session over INPUT split into newline chunks and return"
      "the ordered contract records."
      #((parameters
         (input (type string)
          (description
           ("Interaction-input text to split into newline-kept chunks"
             "and drive.")))
         (session (type (or symbol string))
          (description ("Session identifier symbol or string for the record stream.")))
         (maybe-options (type list)
          (description
           ("Optional single-element list holding the REPL option"
             "alist."))))
        (returns (type list)
         (description "The ordered list of emitted contract record datums."))
        (effects host-eval allocation error))
      (apply cli-repl-drive
             (repl--list-chunk-source (repl--split-lines input))
             session
             maybe-options))

    ;;;; Transcript capture and replay

    ;; The canonical capture format is the `datum' chrome's record stream: one
    ;; contract record datum per line, written by the consent writer.  The
    ;; writer emits plain symbols, numerals, strings, and booleans, so the
    ;; standard reader reloads each record with the same representation the live
    ;; loop produces for the fields replay consults (`source', `complete').
    (define (cli-repl-records-from-datum-stream text)
      "Reload a captured `datum'-chrome record stream TEXT into the list of"
      "contract records, reading with the standard reader the capture format"
      "is written for."
      #((parameters
         (text (type string)
          (description
           ("Captured `datum'-chrome stream text, one record datum per"
             "line."))))
        (returns (type list)
         (description
          ("The ordered list of contract record datums reloaded from"
            "the stream.")))
        (effects allocation))
      (let ((port (open-input-string text)))
        (let loop ((records '()))
          (let ((datum (read port)))
            (if (eof-object? datum)
                (reverse records)
                (loop (cons datum records)))))))

    (define (cli-repl-submissions-from-records records)
      "Return the external source text of each complete submission in RECORDS,"
      "in order.  A `repl-submission' with `(complete #t)' contributes its"
      "`source'; an incomplete (EOF-truncated) submission, prompts, results,"
      "conditions, and the exit record contribute nothing, so the result is"
      "exactly the forms a replay can re-feed."
      #((parameters
         (records (type list)
          (description
           ("List of contract record datums to scan for complete"
             "submissions."))))
        (returns (type string)
         (description
          ("The ordered list of source strings for each complete"
            "submission.")))
        (effects allocation))
      (let loop ((records records) (sources '()))
        (cond
         ((null? records) (reverse sources))
         ((and (pair? (car records))
               (eq? (car (car records)) 'repl-submission)
               (eq? (repl--field (car records) 'complete) #t))
          (loop (cdr records)
                (cons (repl--field (car records) 'source) sources)))
         (else (loop (cdr records) sources)))))

    (define (cli-repl-replay-input records)
      "Reconstruct the interaction-input string that replays RECORDS: each"
      "complete submission's source followed by a newline, so a fresh loop"
      "reads the same forms."
      #((parameters
         (records (type list)
          (description
           ("List of contract record datums whose complete submissions"
             "are replayed."))))
        (returns (type string)
         (description
          ("The interaction-input string: each submission source plus"
            "a trailing newline.")))
        (effects allocation))
      (let loop ((sources (cli-repl-submissions-from-records records)) (parts '()))
        (if (null? sources)
            (apply string-append (reverse parts))
            (loop (cdr sources) (cons "\n" (cons (car sources) parts))))))

    (define (cli-repl-replay-records records session . maybe-options)
      "Replay the captured RECORDS by re-feeding their complete submissions"
      "to a fresh SESSION, returning the new contract record stream."
      "Reproduces submissions, ordering, prompts, the close record, and"
      "deterministic results/conditions; a live host effect the replay"
      "posture does not grant fails closed as a `repl-condition' rather"
      "than reproducing the recorded value (compare with"
      "`cli-repl-replay-report')."
      #((parameters
         (records (type list)
          (description
           ("Captured contract record datums whose complete submissions"
             "are re-fed.")))
         (session (type (or symbol string))
          (description
           ("Session identifier symbol or string for the fresh replay"
             "session.")))
         (maybe-options (type list)
          (description
           ("Optional single-element list holding the REPL option"
             "alist."))))
        (returns (type list)
         (description
          ("The new contract record stream produced by replaying the"
            "submissions.")))
        (effects host-eval allocation error))
      (apply cli-repl-records-from-string
             (cli-repl-replay-input records)
             session
             maybe-options))

    ;; A submission outcome is the triple (SOURCE KIND DISPLAY), where KIND is
    ;; `result', `condition', or `none' (an exit form has no outcome) and
    ;; DISPLAY is the outcome's human-readable rendering.  KIND and DISPLAY are
    ;; the contract-meaningful, representation-stable fields the replay report
    ;; compares, so the comparison holds whether a stream came from the live
    ;; loop or from a reloaded datum-stream text.
    (define (repl--outcome-for records submission-id)
      "Return (KIND . DISPLAY) for the result/condition correlated to"
      "SUBMISSION-ID in RECORDS, or (none . #f) when neither is present."
      (let loop ((records records))
        (cond
         ((null? records) (cons 'none #f))
         ((and (pair? (car records))
               (memq (car (car records)) '(repl-result repl-condition))
               (equal? (repl--field (car records) 'submission) submission-id))
          (cons (if (eq? (car (car records)) 'repl-result) 'result 'condition)
                (repl--field (car records) 'display)))
         (else (loop (cdr records))))))

    (define (repl--submission-outcomes records)
      "Return the ordered list of (SOURCE KIND DISPLAY) outcome triples for"
      "each complete submission in RECORDS, correlating each to its"
      "result/condition by submission id."
      (let loop ((rs records) (outcomes '()))
        (cond
         ((null? rs) (reverse outcomes))
         ((and (pair? (car rs))
               (eq? (car (car rs)) 'repl-submission)
               (eq? (repl--field (car rs) 'complete) #t))
          (let ((outcome (repl--outcome-for
                          records (repl--field (car rs) 'id))))
            (loop (cdr rs)
                  (cons (list (repl--field (car rs) 'source)
                              (car outcome) (cdr outcome))
                        outcomes))))
         (else (loop (cdr rs) outcomes)))))

    (define (repl--outcome-fields outcome)
      "Render an outcome triple OUTCOME as `(kind K) (display D)' fields, or"
      "`(kind absent)' when OUTCOME is #f (no paired submission)."
      (if outcome
          (list (list 'kind (cadr outcome))
                (list 'display (list-ref outcome 2)))
          (list (list 'kind 'absent))))

    (define (repl--divergence index source captured-outcome replayed-outcome)
      "Build a `repl-replay-divergence' datum for the submission at INDEX."
      (append
       (list 'repl-replay-divergence
             (list 'index (consent-make-canonical-integer index))
             (list 'source source))
       (list (cons 'captured (repl--outcome-fields captured-outcome)))
       (list (cons 'replayed (repl--outcome-fields replayed-outcome)))))

    (define (repl--outcome-divergences captured replayed index acc)
      "Walk the CAPTURED and REPLAYED outcome triples in parallel from"
      "INDEX, accumulating a divergence datum for each kind/display mismatch"
      "or unpaired submission."
      (cond
       ((and (null? captured) (null? replayed)) (reverse acc))
       ((null? captured)
        (repl--outcome-divergences
         '() (cdr replayed) (+ index 1)
         (cons (repl--divergence index (car (car replayed)) #f (car replayed))
               acc)))
       ((null? replayed)
        (repl--outcome-divergences
         (cdr captured) '() (+ index 1)
         (cons (repl--divergence index (car (car captured)) (car captured) #f)
               acc)))
       (else
        (let ((c (car captured)) (r (car replayed)))
          (if (and (eq? (cadr c) (cadr r))
                   (equal? (list-ref c 2) (list-ref r 2)))
              (repl--outcome-divergences (cdr captured) (cdr replayed)
                                         (+ index 1) acc)
              (repl--outcome-divergences
               (cdr captured) (cdr replayed) (+ index 1)
               (cons (repl--divergence index (car c) c r) acc)))))))

    (define (cli-repl-replay-report captured replayed)
      "Compare the per-submission outcomes of the CAPTURED and REPLAYED"
      "record streams and return a `repl-replay-report' datum."
      "Each complete submission's outcome is its result/condition `kind'"
      "(`result', `condition', or `none') and `display' rendering,"
      "correlated by submission id and compared by position.  The report"
      "is `reproduced' when every compared submission matches in kind and"
      "display; otherwise `diverged', with one `repl-replay-divergence' per"
      "mismatched or unpaired submission.  A captured `result' that replays"
      "as a `condition' is the documented fail-closed signal for a live"
      "host effect the replay posture does not grant."
      #((parameters
         (captured (type list)
          (description
           ("Captured contract record stream providing the reference"
             "outcomes.")))
         (replayed (type list)
          (description
           ("Replayed contract record stream compared against the"
             "captured outcomes."))))
        (returns (type repl-replay-report)
         (description
          ("A `repl-replay-report' datum: reproduced, or diverged with"
            "per-submission divergences.")))
        (effects allocation))
      (let* ((captured-outcomes (repl--submission-outcomes captured))
             (replayed-outcomes (repl--submission-outcomes replayed))
             (divergences (repl--outcome-divergences
                           captured-outcomes replayed-outcomes 1 '())))
        (list 'repl-replay-report
              (list 'status (if (null? divergences) 'reproduced 'diverged))
              (list 'submissions
                    (consent-make-canonical-integer (length captured-outcomes)))
              (list 'divergences divergences))))

    ;;;; Terminal entry

    (define (repl--color-inline argument)
      "Return the VALUE in a `--color=VALUE' ARGUMENT, or #f for any other argument."
      (let* ((prefix "--color=")
             (length (string-length prefix)))
        (and (>= (string-length argument) length)
             (string=? (substring argument 0 length) prefix)
             (substring argument length (string-length argument)))))

    (define (cli-repl-parse-options arguments)
      "Parse ARGUMENTS into the REPL option alist ((session . S) (chrome"
      ". C) (color . M) (replay . F)), honoring --session NAME, --chrome"
      "NAME, --color=auto|always|never (or the spaced --color VALUE), and"
      "--replay FILE (reload and replay the captured transcript at FILE, #f"
      "for the ordinary stdin session); later flags win, unrecognized"
      "arguments are ignored, and the caller validates chrome and color"
      "against the registry and the known modes."
      #((parameters
         (arguments (type string)
          (description
           ("List of command-line argument strings to parse for REPL"
             "flags."))))
        (returns (type list)
         (description
          ("The option alist with session, chrome, color, and replay"
            "entries.")))
        (effects allocation))
      (let loop ((arguments arguments)
                 (session #f) (chrome #f) (color #f) (replay #f))
        (cond
         ((null? arguments)
          (list (cons 'session (or session "repl-main"))
                (cons 'chrome (or chrome (cli-repl-chrome-default-name)))
                (cons 'color (or color 'auto))
                (cons 'replay replay)))
         ((and (string=? (car arguments) "--session") (pair? (cdr arguments)))
          (loop (cddr arguments) (cadr arguments) chrome color replay))
         ((and (string=? (car arguments) "--chrome") (pair? (cdr arguments)))
          (loop (cddr arguments) session (string->symbol (cadr arguments))
                color replay))
         ((and (string=? (car arguments) "--color") (pair? (cdr arguments)))
          (loop (cddr arguments) session chrome
                (string->symbol (cadr arguments)) replay))
         ((and (string=? (car arguments) "--replay") (pair? (cdr arguments)))
          (loop (cddr arguments) session chrome color (cadr arguments)))
         ((repl--color-inline (car arguments))
          => (lambda (value)
               (loop (cdr arguments) session chrome
                     (string->symbol value) replay)))
         (else (loop (cdr arguments) session chrome color replay)))))

    (define (repl--option options name)
      "Return the value bound to NAME in the parsed OPTIONS alist."
      (cdr (assq name options)))

    (define (repl--rendering-writer chrome color? port)
      "Return a write-record procedure that paints each record with CHROME"
      "under COLOR? to PORT, flushing so a no-newline prompt appears before"
      "the next blocking read."
      (lambda (record)
        (let ((painted (cli-repl-chrome-paint (chrome record) color?)))
          (when painted
            (write-string painted port)
            (flush-output-port port)))))

    (define (repl--output-writer echo color? output-port record-port)
      "Return a write-output procedure realizing the program-output policy."
      "The `comment' chrome OWNS program output: it renders each chunk"
      "commented (`;;   :: ') and aligned onto RECORD-PORT (the control"
      "channel) so the captured transcript replays it, and writes nothing to"
      "stdout.  Every other chrome leaves program output raw on OUTPUT-PORT"
      "(stdout) and untouched by the control channel.  ECHO -- the chrome's"
      "output formatter -- yields the comment chrome's control-channel"
      "segments, or #f for a chrome that keeps output raw; that #f is the"
      "switch between the two streams.  The engine stays chrome-agnostic; this"
      "writer carries the policy."
      (lambda (output)
        (let ((segments (echo output)))
          (if segments
              (let ((painted (cli-repl-chrome-paint segments color?)))
                (when painted
                  (write-string painted record-port)
                  (flush-output-port record-port)))
              (begin
                (write-string output output-port)
                (flush-output-port output-port))))))

    (define (cli-repl-capture-from-string input session chrome-name color?
                                          . maybe-input-echoed?)
      "Drive a REPL over INPUT under SESSION and return the pair"
      "(CONTROL . PROGRAM-OUTPUT): the painted control-channel text and the"
      "raw program-output (stdout) stream, kept on the two ports the live"
      "binary uses.  This is how the program-output policy is asserted:"
      "under the `comment' chrome program output is rendered, commented,"
      "into CONTROL and PROGRAM-OUTPUT is empty; under every other chrome"
      "program output is raw in PROGRAM-OUTPUT and CONTROL carries records"
      "only.  COLOR? paints the control channel; the optional INPUT-ECHOED?"
      "flag (default #f) models a host that already echoes interaction"
      "input."
      #((parameters
         (input (type string)
          (description "Interaction-input text driven through the REPL."))
         (session (type (or symbol string))
          (description ("Session identifier symbol or string for the record stream.")))
         (chrome-name (type symbol)
          (description
           ("Chrome name symbol selecting the control-channel"
             "rendering.")))
         (color? (type boolean)
          (description "True to paint the control channel with ANSI color."))
         (maybe-input-echoed? (type list)
          (description
           ("Optional flag list; #t models a host already echoing"
             "input."))))
        (returns (type pair)
         (description
          ("A pair (CONTROL . PROGRAM-OUTPUT) of painted control text"
            "and raw stdout text.")))
        (effects host-eval allocation error))
      (let ((chrome (cli-repl-chrome-lookup chrome-name))
            (echo (cli-repl-chrome-output-formatter chrome-name session))
            (control-port (open-output-string))
            (output-port (open-output-string))
            (input-echoed? (and (pair? maybe-input-echoed?)
                                (car maybe-input-echoed?))))
        (parameterize ((cli-repl-chrome-input-echoed? input-echoed?))
          (cli-repl-run
           (repl--list-chunk-source (repl--split-lines input))
           (repl--rendering-writer chrome color? control-port)
           (repl--output-writer echo color? output-port control-port)
           session))
        (cons (get-output-string control-port)
              (get-output-string output-port))))

    (define (cli-repl-rendered-from-string input session chrome-name color?
                                           . maybe-input-echoed?)
      "Drive a REPL over INPUT under SESSION and return the CHROME-NAME"
      "chrome's control-channel text, painted when COLOR? is true; the"
      "host-neutral, TTY-free hook the tests assert chrome output against."
      "The control channel is the full replayable transcript: records, plus"
      "-- under the `comment' chrome -- the commented `;;   :: ' rendering"
      "of any program output (which `comment' owns).  The raw"
      "program-output stream is the cdr of `cli-repl-capture-from-string'"
      "and is dropped here.  The optional INPUT-ECHOED? flag (default #f)"
      "models a host that already echoes interaction input -- an"
      "interactive TTY -- so the comment chrome suppresses its own"
      "submission echo just as the live terminal entry does."
      #((parameters
         (input (type string)
          (description "Interaction-input text driven through the REPL."))
         (session (type (or symbol string))
          (description ("Session identifier symbol or string for the record stream.")))
         (chrome-name (type symbol)
          (description
           ("Chrome name symbol selecting the control-channel"
             "rendering.")))
         (color? (type boolean)
          (description "True to paint the control channel with ANSI color."))
         (maybe-input-echoed? (type list)
          (description
           ("Optional flag list; #t models a host already echoing"
             "input."))))
        (returns (type string)
         (description
          ("The CHROME-NAME chrome's control-channel text, painted"
            "when COLOR? is true.")))
        (effects host-eval allocation error))
      (car (apply cli-repl-capture-from-string
                  input session chrome-name color? maybe-input-echoed?)))

    (define (repl--read-file path)
      "Return the entire contents of the file at PATH as a string."
      (call-with-input-file path
        (lambda (port)
          (let ((out (open-output-string)))
            (let loop ()
              (let ((chunk (read-string 4096 port)))
                (if (eof-object? chunk)
                    (get-output-string out)
                    (begin (write-string chunk out) (loop)))))))))

    (define (cli-repl-replay-main path session chrome color? record-port)
      "Reload the captured transcript at PATH, replay its complete"
      "submissions to a fresh SESSION, paint the replayed record stream"
      "through CHROME under COLOR? onto RECORD-PORT, append the"
      "`repl-replay-report' datum, and return 0 when the replay reproduced"
      "the captured outcomes or 1 when it diverged."
      "Replay uses the default fail-closed posture, so an effect that needed"
      "authority the capture had is denied and surfaced as a"
      "`repl-condition' -- a divergence the report records rather than"
      "silently reproducing the recorded value."
      #((parameters
         (path (type string)
          (description
           ("Filesystem path of the captured `datum'-chrome transcript"
             "to reload.")))
         (session (type (or symbol string))
          (description
           ("Session identifier symbol or string for the fresh replay"
             "session.")))
         (chrome (type procedure)
          (description
           ("Chrome procedure painting each replayed record for"
             "RECORD-PORT.")))
         (color? (type boolean)
          (description "True to paint the replayed record stream with ANSI color."))
         (record-port (type port)
          (description
           ("Output port receiving the painted replay stream and report"
             "datum."))))
        (returns (type exact-integer)
         (description
          ("0 when the replay reproduced the captured outcomes, 1 when"
            "it diverged.")))
        (effects host-eval state-read state-write allocation error))
      (let* ((captured (cli-repl-records-from-datum-stream (repl--read-file path)))
             (replayed (cli-repl-replay-records captured session))
             (write-record (repl--rendering-writer chrome color? record-port))
             (report (cli-repl-replay-report captured replayed)))
        (for-each write-record replayed)
        ;; The report is a meta-record no interaction chrome renders, so it is
        ;; written raw (one datum) regardless of the active chrome.
        (write-string (string-append (consent-datum->external report) "\n")
                      record-port)
        (flush-output-port record-port)
        (if (eq? (repl--field report 'status) 'reproduced) 0 1)))

    (define (repl--fatal message detail)
      "Write MESSAGE and DETAIL to the control channel and exit with status 2."
      (let ((port (current-error-port)))
        (display "consent-repl: " port)
        (display message port)
        (display detail port)
        (newline port)
        (exit 2)))

    (define (cli-repl-main)
      "Entry point: read forms from stdin, paint each record through the"
      "selected chrome onto stderr, leave program output on stdout, then"
      "exit with the close-status code."
      "With `--replay FILE', reload that captured transcript instead of"
      "reading stdin, replay its submissions to a fresh session, and exit"
      "0 (reproduced) or 1 (diverged) per the replay report."
      #((parameters)
        (returns
         . ("Does not return normally: exits the process with the"
            "close-status or replay code."))
        (effects host-eval state-read state-write error allocation))
      (let* ((options (cli-repl-parse-options (cdr (command-line))))
             (session (repl--option options 'session))
             (chrome-name (repl--option options 'chrome))
             (color-mode (repl--option options 'color))
             (replay-path (repl--option options 'replay))
             (chrome (cli-repl-chrome-lookup chrome-name))
             (record-port (current-error-port))
             (input-port (current-input-port))
             (output-port (current-output-port)))
        (unless chrome
          (repl--fatal "unknown chrome: " (symbol->string chrome-name)))
        (unless (memq color-mode '(auto always never))
          (repl--fatal "unknown color mode: " (symbol->string color-mode)))
        (let* ((no-color-value (get-environment-variable "NO_COLOR"))
               (no-color? (and no-color-value
                               (> (string-length no-color-value) 0)))
               (color? (cli-repl-chrome-color?
                        color-mode no-color? (repl--port-tty? record-port))))
          (if replay-path
              (exit (cli-repl-replay-main replay-path session chrome
                                          color? record-port))
              (let* (;; An interactive terminal echoes each typed form in cooked
                     ;; mode, so stdin being a TTY means the form is already on
                     ;; screen; the comment chrome then suppresses its own echo
                     ;; to keep one copy.
                     (input-echoed? (repl--port-tty? input-port))
                     (read-chunk
                      (lambda ()
                        (let ((line (read-line)))
                          (if (eof-object? line)
                              line
                              (string-append line "\n")))))
                     (write-record
                      (repl--rendering-writer chrome color? record-port))
                     ;; The `comment' chrome owns program output, rendering it
                     ;; commented onto the control channel (stderr) so the
                     ;; transcript replays and stdout stays clean; every other
                     ;; chrome leaves program output raw on stdout.
                     (write-output
                      (repl--output-writer
                       (cli-repl-chrome-output-formatter chrome-name session)
                       color? output-port record-port)))
                (exit
                 (parameterize ((cli-repl-chrome-input-echoed? input-echoed?))
                   (cli-repl-run read-chunk write-record
                                 write-output session))))))))))
