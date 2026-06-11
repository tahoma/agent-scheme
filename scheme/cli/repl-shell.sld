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
;;; on the control channel (stderr); program output on stdout is never touched.
;;; `--chrome datum' recovers the canonical record stream and is always
;;; reachable.

(define-library (cli repl-shell)
  (export cli-repl-drive
          cli-repl-records-from-string
          cli-repl-run
          cli-repl-parse-options
          cli-repl-rendered-from-string
          cli-repl-main)
  (import (scheme base)
          (scheme write)
          (scheme read)
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

    (define (repl--string-contains? haystack needle)
      "Return #t when HAYSTACK contains NEEDLE as a substring."
      (let ((hay (string-length haystack))
            (need (string-length needle)))
        (if (zero? need)
            #t
            (let loop ((start 0))
              (cond
               ((> (+ start need) hay) #f)
               ((let match ((index 0))
                  (cond
                   ((>= index need) #t)
                   ((char=? (string-ref haystack (+ start index))
                            (string-ref needle index))
                    (match (+ index 1)))
                   (else #f)))
                #t)
               (else (loop (+ start 1))))))))

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
    (define (repl--prompt-record session ordinal state pending)
      "Build a `repl-prompt' record for SESSION at ORDINAL with STATE and PENDING."
      (list 'repl-prompt
            (list 'session (repl--session-field session))
            (list 'ordinal (consent-make-canonical-integer ordinal))
            (list 'state state)
            (list 'pending pending)))

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
      "Build a `repl-result' record wrapping EVALUATION-RESULT and DISPLAY at ORDINAL."
      (list 'repl-result
            (list 'id (repl--tag "res" ordinal))
            (list 'submission (repl--tag "sub" ordinal))
            (list 'session (repl--session-field session))
            (list 'evaluation-result evaluation-result)
            (list 'display display)))

    (define (repl--condition-record session ordinal phase recoverable
                                    condition display)
      "Build a `repl-condition' record for PHASE/RECOVERABLE CONDITION at ORDINAL."
      (list 'repl-condition
            (list 'id (repl--tag "cond" ordinal))
            (list 'submission (repl--tag "sub" ordinal))
            (list 'session (repl--session-field session))
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

    ;;;; Evaluation-result inspection

    (define (repl--field datum name)
      "Return the single value of field NAME in tagged list DATUM, or #f."
      (let ((entry (assq name (cdr datum))))
        (and entry (pair? (cdr entry)) (cadr entry))))

    (define (repl--error-result? evaluation-result)
      "Return #t when EVALUATION-RESULT carries an error status."
      (eq? (repl--field evaluation-result 'status) 'error))

    (define (repl--result-display evaluation-result)
      "Return a human-readable display string for a non-error EVALUATION-RESULT."
      (let ((status (repl--field evaluation-result 'status)))
        (cond
         ((eq? status 'values)
          (let ((entry (assq 'values (cdr evaluation-result))))
            (consent-result->external (cons 'values (cadr entry)))))
         (else
          (let ((value (repl--field evaluation-result 'value)))
            (consent-result->external value))))))

    (define (repl--error-condition evaluation-result)
      "Return the debugger-condition datum from an error EVALUATION-RESULT for wrapping in the contract condition field."
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
      "Build a debugger-condition datum for a reader error MESSAGE, shaped like an evaluator condition."
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

    (define (repl--try-read buffer)
      "Read one datum from BUFFER, returning (empty), (complete DATUM NEXT), (incomplete), or (malformed MESSAGE)."
      (call/cc
       (lambda (return)
         (with-exception-handler
          (lambda (condition)
            (let ((message (if (error-object? condition)
                               (error-object-message condition)
                               "reader error")))
              (return
               (if (repl--string-contains? message "unterminated")
                   (list 'incomplete)
                   (list 'malformed message)))))
          (lambda ()
            (let ((result (consent-read-from-string-at buffer 0)))
              (if (consent-read-eof? (car result))
                  (list 'empty)
                  (list 'complete (car result) (cdr result)))))))))

    ;;;; The interaction loop

    (define (repl--callable callback)
      "Return CALLBACK as a directly applicable host procedure.
A self-hosted caller (consent --host-run) passes interpreted closures as
engine callbacks; consent-apply-callable runs those in the calling
program's context while host procedures pass through untouched."
      (if (procedure? callback)
          callback
          (lambda arguments (consent-apply-callable callback arguments))))

    (define (repl--engine read-chunk emit-record emit-output session options)
      "Run the host-neutral loop: read from READ-CHUNK, send records to EMIT-RECORD and program output to EMIT-OUTPUT under SESSION/OPTIONS, returning the close-status exit code."
      (let* ((read-chunk (repl--callable read-chunk))
             (emit-record (repl--callable emit-record))
             (emit-output (repl--callable emit-output))
             (session-id (if (symbol? session)
                             (symbol->string session)
                             session))
             (interaction
              (consent-make-interaction-context
               (cons (cons 'session-id session-id) options)))
             (exit-code 0))
        (define (emit record)
          (when (and (pair? record) (eq? (car record) 'repl-exit))
            (set! exit-code
                  (if (eq? (repl--field record 'status) 'closed-error) 1 0)))
          (emit-record record))
        (define (drain-output!)
          (let ((output (consent-interaction-program-output interaction)))
            (when (> (string-length output) 0)
              (emit-output output))))
        (define (acquire buffer ordinal)
          "Acquire one complete form, returning (values KIND PAYLOAD BUFFER) for KIND complete/malformed/eof/eof-incomplete."
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
              (emit (repl--prompt-record session ordinal 'continuation #t))
              (let ((chunk (read-chunk)))
                (if (eof-object? chunk)
                    (if (repl--blank? buffer)
                        (values 'eof #f buffer)
                        (values 'eof-incomplete buffer buffer))
                    (acquire (string-append buffer chunk) ordinal)))))))
        (define (skip-to-boundary buffer)
          "Return BUFFER past the next newline so a malformed datum does not wedge the session."
          (let ((length (string-length buffer)))
            (let loop ((index 0))
              (cond
               ((>= index length) "")
               ((char=? (string-ref buffer index) #\newline)
                (substring buffer (+ index 1) length))
               (else (loop (+ index 1)))))))
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
                      (rest (substring current next (string-length current))))
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
                   (let ((result (consent-interaction-eval-form
                                  interaction datum)))
                     (drain-output!)
                     (if (repl--error-result? result)
                         (emit (repl--condition-record
                                session ordinal 'eval #t
                                (repl--error-condition result)
                                (repl--error-message result)))
                         (emit (repl--result-record
                                session ordinal result
                                (repl--result-display result))))
                     (loop rest (+ ordinal 1) (+ count 1)))))))))))
        exit-code))

    (define (cli-repl-run read-chunk write-record write-output session
                          . maybe-options)
      "Run a REPL session, streaming records to WRITE-RECORD and program output to WRITE-OUTPUT on separate streams, returning the close-status exit code."
      (repl--engine read-chunk write-record write-output session
                    (if (null? maybe-options) '() (car maybe-options))))

    (define (cli-repl-drive read-chunk session . maybe-options)
      "Drive a REPL session over READ-CHUNK and return the ordered contract records, discarding program output."
      (let ((records '()))
        (repl--engine read-chunk
                      (lambda (record) (set! records (cons record records)))
                      (lambda (output) output)
                      session
                      (if (null? maybe-options) '() (car maybe-options)))
        (reverse records)))

    (define (cli-repl-records-from-string input session . maybe-options)
      "Drive a REPL session over INPUT split into newline chunks and return the ordered contract records."
      (apply cli-repl-drive
             (repl--list-chunk-source (repl--split-lines input))
             session
             maybe-options))

    ;;;; Terminal entry

    (define (repl--color-inline argument)
      "Return the VALUE in a `--color=VALUE' ARGUMENT, or #f for any other argument."
      (let* ((prefix "--color=")
             (length (string-length prefix)))
        (and (>= (string-length argument) length)
             (string=? (substring argument 0 length) prefix)
             (substring argument length (string-length argument)))))

    (define (cli-repl-parse-options arguments)
      "Parse ARGUMENTS into the REPL option alist ((session . S) (chrome . C) (color . M)), honoring --session NAME, --chrome NAME, and --color=auto|always|never (or the spaced --color VALUE); later flags win, unrecognized arguments are ignored, and the caller validates chrome and color against the registry and the known modes."
      (let loop ((arguments arguments) (session #f) (chrome #f) (color #f))
        (cond
         ((null? arguments)
          (list (cons 'session (or session "repl-main"))
                (cons 'chrome (or chrome (cli-repl-chrome-default-name)))
                (cons 'color (or color 'auto))))
         ((and (string=? (car arguments) "--session") (pair? (cdr arguments)))
          (loop (cddr arguments) (cadr arguments) chrome color))
         ((and (string=? (car arguments) "--chrome") (pair? (cdr arguments)))
          (loop (cddr arguments) session (string->symbol (cadr arguments)) color))
         ((and (string=? (car arguments) "--color") (pair? (cdr arguments)))
          (loop (cddr arguments) session chrome (string->symbol (cadr arguments))))
         ((repl--color-inline (car arguments))
          => (lambda (value)
               (loop (cdr arguments) session chrome (string->symbol value))))
         (else (loop (cdr arguments) session chrome color)))))

    (define (repl--option options name)
      "Return the value bound to NAME in the parsed OPTIONS alist."
      (cdr (assq name options)))

    (define (repl--rendering-writer chrome color? port)
      "Return a write-record procedure that paints each record with CHROME under COLOR? to PORT, flushing so a no-newline prompt appears before the next blocking read."
      (lambda (record)
        (let ((painted (cli-repl-chrome-paint (chrome record) color?)))
          (when painted
            (write-string painted port)
            (flush-output-port port)))))

    (define (cli-repl-rendered-from-string input session chrome-name color?
                                           . maybe-input-echoed?)
      "Drive a REPL over INPUT under SESSION and return the CHROME-NAME chrome's control-channel text, painted when COLOR? is true and discarding program output; the host-neutral, TTY-free hook the tests assert chrome output against.  The optional INPUT-ECHOED? flag (default #f) models a host that already echoes interaction input -- an interactive TTY -- so the comment chrome suppresses its own submission echo just as the live terminal entry does."
      (let ((chrome (cli-repl-chrome-lookup chrome-name))
            (port (open-output-string))
            (input-echoed? (and (pair? maybe-input-echoed?)
                                (car maybe-input-echoed?))))
        (parameterize ((cli-repl-chrome-input-echoed? input-echoed?))
          (cli-repl-run
           (repl--list-chunk-source (repl--split-lines input))
           (repl--rendering-writer chrome color? port)
           (lambda (output) output)
           session))
        (get-output-string port)))

    (define (repl--fatal message detail)
      "Write MESSAGE and DETAIL to the control channel and exit with status 2."
      (let ((port (current-error-port)))
        (display "consent-repl: " port)
        (display message port)
        (display detail port)
        (newline port)
        (exit 2)))

    (define (cli-repl-main)
      "Entry point: read forms from stdin, paint each record through the selected chrome onto stderr, leave program output on stdout, then exit with the close-status code."
      (let* ((options (cli-repl-parse-options (cdr (command-line))))
             (session (repl--option options 'session))
             (chrome-name (repl--option options 'chrome))
             (color-mode (repl--option options 'color))
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
                        color-mode no-color? (repl--port-tty? record-port)))
               ;; An interactive terminal echoes each typed form in cooked mode,
               ;; so stdin being a TTY means the form is already on screen; the
               ;; comment chrome then suppresses its own echo to keep one copy.
               (input-echoed? (repl--port-tty? input-port))
               (read-chunk
                (lambda ()
                  (let ((line (read-line)))
                    (if (eof-object? line)
                        line
                        (string-append line "\n")))))
               (write-record (repl--rendering-writer chrome color? record-port))
               (write-output
                (lambda (output)
                  (write-string output output-port)
                  (flush-output-port output-port))))
          (exit
           (parameterize ((cli-repl-chrome-input-echoed? input-echoed?))
             (cli-repl-run read-chunk write-record write-output session))))))))
