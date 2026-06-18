;;; consent-repl-stream.el --- Incremental stdin REPL over the interaction contract  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Emacs host adapter for the incremental, line-oriented Consent Scheme REPL.
;; This module is the Emacs parity twin of the portable terminal REPL shell
;; (`(cli repl-shell)' in scheme/cli/repl-shell.sld): it implements the
;; host-neutral obligations of the cross-host REPL interaction contract
;; (docs/repl-interaction-contract.md) on the Emacs host -- incremental
;; one-form-at-a-time reading, evaluation in a durable session interaction
;; environment, and emission of the contract's Scheme-readable record vocabulary
;; (`repl-prompt', `repl-submission', `repl-result', `repl-condition',
;; `repl-exit').
;;
;; The loop is a driver over existing substrate, not new runtime mechanism.
;; Durable session evaluation is `consent-interaction-eval-form' over a
;; `consent-make-interaction-context' (consent-eval.el), the Emacs twin of the
;; portable `(consent eval)' interaction context; values, results, and
;; conditions are the existing `(consent result)' datums; reading is the shared
;; recovery-aware reader `consent-read-recover-from-string-at' (consent-reader.el).
;; The driver consumes only interaction input; evaluated forms write their own
;; output to a captured program-output port, so a scripted consumer of program
;; output is never corrupted by prompts, results, or diagnostics.
;;
;; `consent-repl-stream-drive' is a pure function from an interaction-input chunk
;; source to the list of contract records, so the cross-host conformance corpus
;; (#392) and the Emacs smoke tests can assert the emitted record stream without
;; a terminal.  `consent-repl-stream-main' wires that driver to batch stdin (the
;; error stream carries records, stdout carries program output) for a scripted
;; session, and `consent-repl-stream' is an interactive command that drives a
;; submitted source string and renders the records in a transcript buffer.
;;
;; The interactive command renders its transcript buffer through the shared
;; chrome model (`consent-repl-chrome.el', the Emacs parity twin of the portable
;; `(cli repl-chrome)' layer): the same named chromes and the same
;; record-to-role mapping, realized as Emacs faces.  The default is `comment',
;; consistent with the portable terminal default; `datum' recovers the canonical
;; raw record stream in the buffer and is always reachable.  The batch entry and
;; the pure `consent-repl-stream-drive' driver keep emitting that raw record
;; stream untouched -- it is the canonical surface the parity corpus asserts
;; against both hosts.
;;
;; This entry is deliberately minimal: full line editing, history, completion,
;; and comint UI polish are out of scope (they belong to later issues).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-repl-chrome)
(require 'consent-result)
(require 'consent-session)

(defconst consent-repl-stream-default-session "repl-main"
  "Default session id used by the incremental Consent Scheme REPL entry.")

(defconst consent-repl-stream--eof (make-symbol "consent-repl-stream-eof")
  "Sentinel a chunk source returns when the interaction input is exhausted.")

;;;; Scheme-readable leaf helpers

(defun consent-repl-stream--bool (value)
  "Return VALUE as a Scheme-readable boolean datum."
  (if value consent-true consent-false))

(defun consent-repl-stream--int (value)
  "Return integer VALUE as a Scheme-readable number datum."
  (consent--make-canonical-integer value))

(defun consent-repl-stream--sym (name)
  "Return NAME as a Scheme symbol datum."
  (consent--intern-symbol name))

(defun consent-repl-stream--session-field (session)
  "Return SESSION rendered as a symbol datum for a contract record field."
  (consent-repl-stream--sym
   (cond
    ((consent-symbol-p session) (consent-symbol-name session))
    ((symbolp session) (symbol-name session))
    (t session))))

(defun consent-repl-stream--tag (prefix ordinal)
  "Return a record-id symbol such as `sub-3' for PREFIX and ORDINAL."
  (consent-repl-stream--sym (format "%s-%d" prefix ordinal)))

(defun consent-repl-stream--field (datum name)
  "Return the single value of field NAME (a string) in record DATUM, or nil."
  (let ((entry (seq-find
                (lambda (candidate)
                  (and (consp candidate)
                       (consent-symbol-p (car candidate))
                       (equal (consent-symbol-name (car candidate)) name)))
                (cdr-safe datum))))
    (and entry (cadr entry))))

;;;; Contract record constructors

(defun consent-repl-stream--prompt-record (session ordinal state pending
                                                   &optional pending-stack)
  "Build a `repl-prompt' record for SESSION at ORDINAL with STATE and PENDING.
A continuation prompt additionally carries the reader's pending-nesting
indicator, derived from the optional open-construct stack PENDING-STACK of
the incomplete read (innermost first): `nesting' is the open-construct count
and `pending-kind' the innermost construct kind, or the symbol `datum' when a
datum prefix is pending with no construct open."
  (append
   (list (consent-repl-stream--sym "repl-prompt")
         (list (consent-repl-stream--sym "session")
               (consent-repl-stream--session-field session))
         (list (consent-repl-stream--sym "ordinal")
               (consent-repl-stream--int ordinal))
         (list (consent-repl-stream--sym "state")
               (consent-repl-stream--sym state))
         (list (consent-repl-stream--sym "pending")
               (consent-repl-stream--bool pending)))
   (when (equal state "continuation")
     (let ((stack (and (consp pending-stack) pending-stack)))
       (list (list (consent-repl-stream--sym "nesting")
                   (consent-repl-stream--int (length stack)))
             (list (consent-repl-stream--sym "pending-kind")
                   (consent-repl-stream--sym
                    (symbol-name (if stack (car stack) 'datum)))))))))

(defun consent-repl-stream--submission-record (session ordinal source complete eof)
  "Build a `repl-submission' record for SOURCE read at ORDINAL in SESSION."
  (list (consent-repl-stream--sym "repl-submission")
        (list (consent-repl-stream--sym "id")
              (consent-repl-stream--tag "sub" ordinal))
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
        (list (consent-repl-stream--sym "ordinal")
              (consent-repl-stream--int ordinal))
        (list (consent-repl-stream--sym "source") source)
        (list (consent-repl-stream--sym "complete")
              (consent-repl-stream--bool complete))
        (list (consent-repl-stream--sym "eof")
              (consent-repl-stream--bool eof))))

(defun consent-repl-stream--result-record (session ordinal evaluation-result display)
  "Build a `repl-result' record wrapping EVALUATION-RESULT and DISPLAY at ORDINAL.
The `ordinal' field mirrors `repl-prompt' so a pure chrome can right-align the
result marker to the prompt-gutter width without coupling to the `submission' id
format."
  (list (consent-repl-stream--sym "repl-result")
        (list (consent-repl-stream--sym "id")
              (consent-repl-stream--tag "res" ordinal))
        (list (consent-repl-stream--sym "submission")
              (consent-repl-stream--tag "sub" ordinal))
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
        (list (consent-repl-stream--sym "ordinal")
              (consent-repl-stream--int ordinal))
        (list (consent-repl-stream--sym "evaluation-result") evaluation-result)
        (list (consent-repl-stream--sym "display") display)))

(defun consent-repl-stream--condition-record
    (session ordinal phase recoverable condition display)
  "Build a `repl-condition' record for PHASE/RECOVERABLE CONDITION at ORDINAL.
The `ordinal' field mirrors `repl-prompt' so a pure chrome can right-align the
condition marker to the prompt-gutter width."
  (list (consent-repl-stream--sym "repl-condition")
        (list (consent-repl-stream--sym "id")
              (consent-repl-stream--tag "cond" ordinal))
        (list (consent-repl-stream--sym "submission")
              (consent-repl-stream--tag "sub" ordinal))
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
        (list (consent-repl-stream--sym "ordinal")
              (consent-repl-stream--int ordinal))
        (list (consent-repl-stream--sym "phase")
              (consent-repl-stream--sym phase))
        (list (consent-repl-stream--sym "recoverable")
              (consent-repl-stream--bool recoverable))
        (list (consent-repl-stream--sym "condition") condition)
        (list (consent-repl-stream--sym "display") display)))

(defun consent-repl-stream--exit-record (session reason status count detail)
  "Build a `repl-exit' record closing SESSION with REASON, STATUS, COUNT, DETAIL."
  (list (consent-repl-stream--sym "repl-exit")
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
        (list (consent-repl-stream--sym "reason")
              (consent-repl-stream--sym reason))
        (list (consent-repl-stream--sym "status")
              (consent-repl-stream--sym status))
        (list (consent-repl-stream--sym "count")
              (consent-repl-stream--int count))
        (list (consent-repl-stream--sym "detail")
              (or detail consent-false))))

;;;; Evaluation-result inspection

(defun consent-repl-stream--error-result-p (evaluation-result)
  "Return non-nil when EVALUATION-RESULT carries an error status."
  (let ((status (consent-repl-stream--field evaluation-result "status")))
    (and (consent-symbol-p status)
         (equal (consent-symbol-name status) "error"))))

(defun consent-repl-stream--result-display (evaluation-result)
  "Return a human-readable display string for a non-error EVALUATION-RESULT."
  (let ((status (consent-repl-stream--field evaluation-result "status")))
    (if (and (consent-symbol-p status)
             (equal (consent-symbol-name status) "values"))
        (consent-result->external
         (cons (consent-repl-stream--sym "values")
               (consent-repl-stream--field evaluation-result "values")))
      (consent-result->external
       (consent-repl-stream--field evaluation-result "value")))))

(defun consent-repl-stream--error-subfields (evaluation-result)
  "Return the error field's sub-field list from EVALUATION-RESULT, or nil.
The `error' field carries several sub-fields -- `(error (condition ...)
\(host-condition ...) (message ...))' -- so a single-value accessor cannot
reach inside it; this returns the sub-field list for
`consent-repl-stream--field'."
  (let ((entry (seq-find
                (lambda (candidate)
                  (and (consp candidate)
                       (consent-symbol-p (car candidate))
                       (equal (consent-symbol-name (car candidate)) "error")))
                (cdr-safe evaluation-result))))
    (cdr-safe entry)))

(defun consent-repl-stream--error-condition (evaluation-result)
  "Return the condition datum from an error EVALUATION-RESULT for the record."
  (let ((subfields (consent-repl-stream--error-subfields evaluation-result)))
    (or (and subfields
             (consent-repl-stream--field
              (cons (consent-repl-stream--sym "error") subfields)
              "condition"))
        (list (consent-repl-stream--sym "condition")
              (list (consent-repl-stream--sym "type")
                    (consent-repl-stream--sym "evaluation-error"))))))

(defun consent-repl-stream--error-message (evaluation-result)
  "Return the host message string for an error EVALUATION-RESULT."
  (let ((subfields (consent-repl-stream--error-subfields evaluation-result)))
    (or (and subfields
             (consent-repl-stream--field
              (cons (consent-repl-stream--sym "error") subfields)
              "message"))
        "evaluation error")))

(defun consent-repl-stream--read-condition (message)
  "Build a condition datum for a reader-error MESSAGE shaped like an evaluator one."
  (list (consent-repl-stream--sym "condition")
        (list (consent-repl-stream--sym "type")
              (consent-repl-stream--sym "reader-error"))
        (list (consent-repl-stream--sym "message") message)
        (list (consent-repl-stream--sym "phase")
              (consent-repl-stream--sym "read"))))

;;;; Explicit-exit recognition

(defun consent-repl-stream--exit-form-p (datum)
  "Return non-nil when reader DATUM is a process-context exit/emergency-exit call."
  (let ((stripped (consent--strip-identifiers datum)))
    (and (consp stripped)
         (consent-symbol-p (car stripped))
         (member (consent-symbol-name (car stripped))
                 '("exit" "emergency-exit"))
         t)))

(defun consent-repl-stream--exit-disposition (datum)
  "Return (STATUS . DETAIL) for an exit DATUM per the close-status rules."
  (let ((stripped (consent--strip-identifiers datum)))
    (if (or (null (cdr stripped)) (not (consp (cdr stripped))))
        (cons "closed-ok" nil)
      (let ((rendered (consent-value->external (cadr stripped))))
        (if (or (equal rendered "#t") (equal rendered "0"))
            (cons "closed-ok" nil)
          (cons "closed-error" rendered))))))

;;;; Incremental reading and chunk sources

(defun consent-repl-stream--diagnostic-message (diagnostic)
  "Return the human-readable message string carried by recovery DIAGNOSTIC."
  (or (and diagnostic (consent-repl-stream--field diagnostic "message"))
      "reader error"))

(defun consent-repl-stream--try-read (buffer)
  "Read one datum from BUFFER at position 0.
Return one of (complete DATUM NEXT), (empty), (incomplete PENDING), or
(malformed MESSAGE NEXT).  PENDING is the reader's open-construct stack at
the incomplete read, innermost first, so the continuation prompt can render
nesting depth."
  (let ((step (consent-read-recover-from-string-at buffer 0)))
    (pcase (consent-recovery-step-status step)
      ('datum
       (list 'complete
             (consent-recovery-step-datum step)
             (consent-recovery-step-next step)))
      ('eof (list 'empty))
      ('incomplete (list 'incomplete (consent-recovery-step-pending step)))
      ('invalid
       (list 'malformed
             (consent-repl-stream--diagnostic-message
              (consent-recovery-step-diagnostic step))
             (consent-recovery-step-next step))))))

(defun consent-repl-stream--list-chunk-source (chunks)
  "Return a chunk source yielding each string in CHUNKS then the EOF sentinel."
  (let ((remaining chunks))
    (lambda ()
      (if (null remaining)
          consent-repl-stream--eof
        (pop remaining)))))

(defun consent-repl-stream--split-lines (string)
  "Split STRING into newline-terminated chunks, preserving each newline."
  (let ((length (length string))
        (start 0)
        (index 0)
        (chunks nil))
    (while (< index length)
      (when (eq (aref string index) ?\n)
        (push (substring string start (1+ index)) chunks)
        (setq start (1+ index)))
      (setq index (1+ index)))
    (when (> index start)
      (push (substring string start index) chunks))
    (nreverse chunks)))

(defun consent-repl-stream--blank-p (string)
  "Return non-nil when STRING is empty or only whitespace."
  (string-empty-p (string-trim string)))

(defun consent-repl-stream--horizontal-whitespace-p (char)
  "Return non-nil when CHAR is space or tab (horizontal whitespace, not a break)."
  (or (eq char ?\s) (eq char ?\t)))

(defun consent-repl-stream--submission-boundary (buffer next)
  "Return the index in BUFFER where program input begins after a form ending at NEXT.
Skip horizontal whitespace after the form; if a newline follows, consume exactly
that newline as the submission terminator (the Enter that submits a line is not
program data), so program input begins on the next line.  Otherwise the boundary
is NEXT and any same-line trailing text is program input for an evaluated read."
  (let ((length (length buffer))
        (index next)
        (result nil))
    (while (and (not result) (< index length))
      (let ((char (aref buffer index)))
        (cond
         ((consent-repl-stream--horizontal-whitespace-p char)
          (setq index (1+ index)))
         ((eq char ?\n) (setq result (1+ index)))
         (t (setq result next)))))
    (or result next)))

;; A REPL session is consented by invocation -- the caller handed it this stdin --
;; so program input is authorized by default with this `port'/`read' grant backed
;; by `stdin'.  Ambient effects still gate separately.
(defconst consent-repl-stream--program-input-grant
  '(capability-grant (id program-input) (domain port)
                     (operations read close) (scope (backing stdin))
                     (expires never))
  "The consent-by-invocation stdin grant a REPL session attaches by default.")

(defun consent-repl-stream--interaction-options (session-id read-chunk options)
  "Augment REPL OPTIONS with the session id, a program-input reader over
READ-CHUNK, and the consent-by-invocation stdin grant, so the interaction context
shares one stdin cursor between the form reader and evaluated reads.  Grants
already in OPTIONS are preserved by merging into the leading :capability-grants."
  (let ((reader (lambda ()
                  (let ((chunk (funcall read-chunk)))
                    (if (eq chunk consent-repl-stream--eof) nil chunk))))
        (grants (cons consent-repl-stream--program-input-grant
                      (plist-get options :capability-grants))))
    (append (list :session-id session-id
                  :program-input-reader reader
                  :capability-grants grants)
            options)))

;;;; The interaction loop

(defun consent-repl-stream--engine (read-chunk emit-record emit-output session options)
  "Run the host-neutral REPL loop and return the close-status exit code.
Read interaction input from READ-CHUNK (each call returns a chunk string or the
EOF sentinel), send contract records to EMIT-RECORD and program output to
EMIT-OUTPUT on separate streams, under SESSION and evaluator OPTIONS."
  (let* ((session-id (cond ((stringp session) session)
                           ((consent-symbol-p session)
                            (consent-symbol-name session))
                           ((symbolp session) (symbol-name session))
                           (t (format "%s" session))))
         (interaction-options
          (consent-repl-stream--interaction-options
           session-id read-chunk options))
         ;; The initial session keeps its own transient context (unchanged
         ;; behavior); once a `switch-session'/`create-session' verb sets
         ;; `consent-session-current-id' to a durable registry session, the loop
         ;; resolves that session's live environment per form, sharing this one
         ;; stdin cursor so neither session steals the other's input.
         (interaction
          (consent-make-interaction-context interaction-options))
         (shared-input-port
          (consent-interaction-program-input-port interaction))
         (exit-code 0))
    (setq consent-session-current-id session-id)
    (cl-labels
        ((current-interaction ()
           (let ((id consent-session-current-id))
             (if (and id
                      (not (equal id session-id))
                      (consent-session--maybe id))
                 (consent-session-interaction-context
                  id
                  (append (list :program-input-port shared-input-port)
                          interaction-options))
               interaction)))
         (emit (record)
           (when (and (consp record)
                      (consent-symbol-p (car record))
                      (equal (consent-symbol-name (car record)) "repl-exit"))
             (let ((status (consent-repl-stream--field record "status")))
               (setq exit-code
                     (if (and (consent-symbol-p status)
                              (equal (consent-symbol-name status)
                                     "closed-error"))
                         1 0))))
           (funcall emit-record record))
         (drain-output! (turn-interaction)
           (let ((output (consent-interaction-program-output turn-interaction)))
             (when (> (length output) 0)
               (funcall emit-output output))))
         (next-chunk () (funcall read-chunk))
         (eof-chunk-p (chunk) (eq chunk consent-repl-stream--eof))
         ;; Acquire one complete form, returning a list (KIND PAYLOAD CURRENT)
         ;; where KIND is complete/malformed/eof/eof-incomplete.
         (acquire (buffer ordinal)
           (let ((outcome (consent-repl-stream--try-read buffer)))
             (pcase (car outcome)
               ('complete (list 'complete (cdr outcome) buffer))
               ('malformed (list 'malformed (cdr outcome) buffer))
               ('empty
                (let ((chunk (next-chunk)))
                  (if (eof-chunk-p chunk)
                      (list 'eof nil buffer)
                    (acquire (concat buffer chunk) ordinal))))
               (_                       ; incomplete
                ;; A partial form is buffered, so the continuation gutter is a
                ;; request for more input: emit (and flush) it *before* the
                ;; blocking read that supplies the continued line.  On a live
                ;; TTY the prompt must front the input the user is about to
                ;; type; emitting it after the read glues the gutter to the next
                ;; result line instead (#448).  Reaching this branch always
                ;; means a partial form is buffered, so the prompt is always
                ;; warranted -- including before an EOF-mid-form, where the
                ;; gutter was shown and the user then hit Ctrl-D.
                (emit (consent-repl-stream--prompt-record
                       session ordinal "continuation" t (cadr outcome)))
                (let ((chunk (next-chunk)))
                  (if (eof-chunk-p chunk)
                      (if (consent-repl-stream--blank-p buffer)
                          (list 'eof nil buffer)
                        (list 'eof-incomplete buffer buffer))
                    (acquire (concat buffer chunk) ordinal))))))))
      (let ((buffer "") (ordinal 1) (count 0) (closed nil))
        (while (not closed)
          (emit (consent-repl-stream--prompt-record session ordinal "ready" nil))
          (pcase-let ((`(,kind ,payload ,current) (acquire buffer ordinal)))
            (pcase kind
              ('eof
               (emit (consent-repl-stream--exit-record
                      session "eof" "closed-ok" count nil))
               (setq closed t))
              ('eof-incomplete
               (let ((source (string-trim payload)))
                 (emit (consent-repl-stream--submission-record
                        session ordinal source nil t))
                 (emit (consent-repl-stream--condition-record
                        session ordinal "read" nil
                        (consent-repl-stream--read-condition
                         "unterminated form at end of input")
                        "unterminated form at end of input"))
                 (emit (consent-repl-stream--exit-record
                        session "eof" "closed-error" count
                        "unterminated form at end of input"))
                 (setq closed t)))
              ('malformed
               (let ((message (car payload))
                     (next (cadr payload)))
                 (emit (consent-repl-stream--condition-record
                        session ordinal "read" t
                        (consent-repl-stream--read-condition message)
                        message))
                 (setq buffer (substring current next))
                 (setq ordinal (1+ ordinal))))
              (_                        ; complete
               (let* ((datum (car payload))
                      (next (cadr payload))
                      (source (string-trim (substring current 0 next)))
                      (boundary
                       (consent-repl-stream--submission-boundary current next))
                      ;; Everything after the submission's terminating newline is
                      ;; this turn's program input, shared on the one stdin cursor.
                      (program-input (substring current boundary)))
                 (cond
                  ((consent-repl-stream--exit-form-p datum)
                   (emit (consent-repl-stream--submission-record
                          session ordinal source t nil))
                   (let ((disposition
                          (consent-repl-stream--exit-disposition datum)))
                     (emit (consent-repl-stream--exit-record
                            session "explicit" (car disposition)
                            (1+ count) (cdr disposition))))
                   (setq closed t))
                  (t
                   (emit (consent-repl-stream--submission-record
                          session ordinal source t nil))
                   ;; Resolve the session this form runs in *now*: a prior form's
                   ;; `switch-session'/`create-session' verb may have changed the
                   ;; default, redirecting this turn to another sandbox
                   ;; environment.  All sessions share one stdin cursor.
                   (let ((turn-interaction (current-interaction)))
                     ;; Seed the shared cursor so an evaluated read consumes the
                     ;; input after this form; whatever it leaves unread threads
                     ;; back as the next form-reading buffer, so neither reader
                     ;; steals the other's characters.
                     (consent-interaction-seed-program-input! turn-interaction
                                                              program-input)
                     (let ((result (consent-interaction-eval-form
                                    turn-interaction datum)))
                       ;; Drain this turn's program output before the result
                       ;; record, binding the ordinal so the `comment' chrome's
                       ;; output formatter aligns its `;;   :: ' gutter to this
                       ;; turn's result marker.
                       (let ((consent-repl-chrome-output-ordinal ordinal))
                         (drain-output! turn-interaction))
                       (if (consent-repl-stream--error-result-p result)
                           (emit (consent-repl-stream--condition-record
                                  session ordinal "eval" t
                                  (consent-repl-stream--error-condition result)
                                  (consent-repl-stream--error-message result)))
                         (emit (consent-repl-stream--result-record
                                session ordinal result
                                (consent-repl-stream--result-display result))))
                       (setq buffer
                             (or (consent-interaction-program-input-remainder
                                  turn-interaction)
                                 program-input))
                       (setq ordinal (1+ ordinal))
                       (setq count (1+ count))))))))))))
      exit-code)))

;;;; Public driver surface

;;;###autoload
(defun consent-repl-stream-run (read-chunk write-record write-output session
                                          &optional options)
  "Run a REPL session, streaming records to WRITE-RECORD and program output to
WRITE-OUTPUT on separate streams, and return the close-status exit code.
READ-CHUNK returns a chunk string or the EOF sentinel each call.  SESSION is the
session id and OPTIONS are evaluator options (`:policy-actions',
`:capability-grants')."
  (consent-repl-stream--engine read-chunk write-record write-output
                               session options))

;;;###autoload
(defun consent-repl-stream-drive (read-chunk session &optional options)
  "Drive a REPL session over READ-CHUNK and return the ordered contract records.
Program output is discarded.  This is the pure, terminal-free hook the
conformance corpus and smoke tests assert the record stream against."
  (let ((records nil))
    (consent-repl-stream--engine
     read-chunk
     (lambda (record) (push record records))
     #'ignore
     session options)
    (nreverse records)))

;;;###autoload
(defun consent-repl-stream-records-from-string (input session &optional options)
  "Drive a REPL session over INPUT split into newline chunks.
Return the ordered contract records for SESSION under evaluator OPTIONS."
  (consent-repl-stream-drive
   (consent-repl-stream--list-chunk-source
    (consent-repl-stream--split-lines input))
   session options))

;;;; Transcript capture and replay

;; The canonical capture format is the `datum' chrome's record stream: one
;; contract record datum per line, written by the consent writer
;; (`consent-result->external').  Reload reads those datums back with the consent
;; reader, so a reloaded record carries the same consent-data representation the
;; live loop emits and the extraction below works on either.  Replay
;; reconstructs the interaction input from the complete submissions and re-drives
;; a FRESH session, so a transcript doubles as a reproducible bug report and a
;; fixture capture.  Live host effects are NOT reproduced: a replay session
;; carries only the authority it is granted, so an effect that succeeded under
;; the captured authority fails closed as a `repl-condition' under a weaker
;; replay posture -- a divergence `consent-repl-stream-replay-report' records
;; rather than letting it pass silently.  This is the Emacs parity twin of the
;; portable `(cli repl-shell)' capture/replay surface
;; (docs/repl-interaction-contract.md, "Capture and Replay").

;;;###autoload
(defun consent-repl-stream-records-from-datum-stream (text)
  "Reload a captured `datum'-chrome record stream TEXT into the list of
contract records, reading with the consent reader the capture format is
written for."
  (consent-read-all text))

(defun consent-repl-stream--sym-name (datum)
  "Return DATUM's symbol name when DATUM is a consent symbol, else nil."
  (and (consent-symbol-p datum) (consent-symbol-name datum)))

(defun consent-repl-stream--complete-submission-p (record)
  "Return non-nil when RECORD is a `repl-submission' with `(complete #t)'."
  (and (consp record)
       (equal (consent-repl-stream--sym-name (car record)) "repl-submission")
       (let ((complete (consent-repl-stream--field record "complete")))
         (and (consent-boolean-p complete) (consent-boolean-value complete)))))

;;;###autoload
(defun consent-repl-stream-submissions-from-records (records)
  "Return the external source text of each complete submission in RECORDS, in order.
A `repl-submission' with `(complete #t)' contributes its `source'; an incomplete
\(EOF-truncated) submission, prompts, results, conditions, and the exit record
contribute nothing, so the result is exactly the forms a replay can re-feed."
  (let (sources)
    (dolist (record records (nreverse sources))
      (when (consent-repl-stream--complete-submission-p record)
        (push (consent-repl-stream--field record "source") sources)))))

;;;###autoload
(defun consent-repl-stream-replay-input (records)
  "Reconstruct the interaction-input string that replays RECORDS.
Each complete submission's source is followed by a newline, so a fresh loop
reads the same forms."
  (mapconcat (lambda (source) (concat source "\n"))
             (consent-repl-stream-submissions-from-records records)
             ""))

;;;###autoload
(defun consent-repl-stream-replay-records (records session &optional options)
  "Replay captured RECORDS by re-feeding their complete submissions to a fresh SESSION.
Return the new contract record stream.  Reproduces submissions, ordering, the
close record, and deterministic results/conditions; a live host effect the
replay posture does not grant fails closed as a `repl-condition' rather than
reproducing the recorded value (compare `consent-repl-stream-replay-report')."
  (consent-repl-stream-records-from-string
   (consent-repl-stream-replay-input records) session options))

;; A submission outcome is the list (SOURCE KIND DISPLAY), where KIND is
;; `result', `condition', or `none' (an exit form has no outcome) and DISPLAY is
;; the outcome's human-readable rendering.  KIND and DISPLAY are the
;; contract-meaningful, representation-stable fields the replay report compares,
;; so the comparison holds whether a stream came from the live loop or a
;; reloaded datum-stream text.
(defun consent-repl-stream--outcome-for (records submission-id)
  "Return (KIND . DISPLAY) for the result/condition correlated to
SUBMISSION-ID in RECORDS, or (none) when neither is present."
  (let ((target (consent-repl-stream--sym-name submission-id)))
    (or (catch 'done
          (dolist (record records)
            (when (and (consp record)
                       (member (consent-repl-stream--sym-name (car record))
                               '("repl-result" "repl-condition"))
                       (equal (consent-repl-stream--sym-name
                               (consent-repl-stream--field record "submission"))
                              target))
              (throw 'done
                     (cons (if (equal (consent-repl-stream--sym-name (car record))
                                      "repl-result")
                               'result 'condition)
                           (consent-repl-stream--field record "display")))))
          nil)
        (cons 'none nil))))

(defun consent-repl-stream--submission-outcomes (records)
  "Return the ordered list of (SOURCE KIND DISPLAY) triples for each
complete submission in RECORDS, correlating each to its result/condition by
submission id."
  (let (outcomes)
    (dolist (record records (nreverse outcomes))
      (when (consent-repl-stream--complete-submission-p record)
        (let ((outcome (consent-repl-stream--outcome-for
                        records (consent-repl-stream--field record "id"))))
          (push (list (consent-repl-stream--field record "source")
                      (car outcome) (cdr outcome))
                outcomes))))))

(defun consent-repl-stream--outcome-fields (outcome)
  "Render an outcome triple OUTCOME as `(kind K) (display D)' fields, or
`(kind absent)' when OUTCOME is nil (no paired submission)."
  (if outcome
      (list (list (consent-repl-stream--sym "kind")
                  (consent-repl-stream--sym (symbol-name (nth 1 outcome))))
            (list (consent-repl-stream--sym "display") (nth 2 outcome)))
    (list (list (consent-repl-stream--sym "kind")
                (consent-repl-stream--sym "absent")))))

(defun consent-repl-stream--divergence (index source captured replayed)
  "Build a `repl-replay-divergence' datum for the submission at INDEX."
  (list (consent-repl-stream--sym "repl-replay-divergence")
        (list (consent-repl-stream--sym "index")
              (consent-repl-stream--int index))
        (list (consent-repl-stream--sym "source") source)
        (cons (consent-repl-stream--sym "captured")
              (consent-repl-stream--outcome-fields captured))
        (cons (consent-repl-stream--sym "replayed")
              (consent-repl-stream--outcome-fields replayed))))

(defun consent-repl-stream--outcome-divergences (captured replayed index acc)
  "Walk the CAPTURED and REPLAYED outcome triples in parallel from INDEX.
Accumulate a divergence datum for each kind/display mismatch or unpaired
submission into ACC."
  (cond
   ((and (null captured) (null replayed)) (nreverse acc))
   ((null captured)
    (consent-repl-stream--outcome-divergences
     nil (cdr replayed) (1+ index)
     (cons (consent-repl-stream--divergence index (car (car replayed))
                                            nil (car replayed))
           acc)))
   ((null replayed)
    (consent-repl-stream--outcome-divergences
     (cdr captured) nil (1+ index)
     (cons (consent-repl-stream--divergence index (car (car captured))
                                            (car captured) nil)
           acc)))
   (t
    (let ((c (car captured)) (r (car replayed)))
      (if (and (eq (nth 1 c) (nth 1 r))
               (equal (nth 2 c) (nth 2 r)))
          (consent-repl-stream--outcome-divergences
           (cdr captured) (cdr replayed) (1+ index) acc)
        (consent-repl-stream--outcome-divergences
         (cdr captured) (cdr replayed) (1+ index)
         (cons (consent-repl-stream--divergence index (car c) c r) acc)))))))

;;;###autoload
(defun consent-repl-stream-replay-report (captured replayed)
  "Compare the per-submission outcomes of CAPTURED and REPLAYED record streams.
Return a `repl-replay-report' datum.  Each complete submission's outcome is its
result/condition `kind' (`result', `condition', or `none') and `display'
rendering, correlated by submission id and compared by position.  The report is
`reproduced' when every compared submission matches in kind and display;
otherwise `diverged', with one `repl-replay-divergence' per mismatched or
unpaired submission.  A captured `result' that replays as a `condition' is the
documented fail-closed signal for a live host effect the replay posture does not
grant."
  (let* ((captured-outcomes (consent-repl-stream--submission-outcomes captured))
         (replayed-outcomes (consent-repl-stream--submission-outcomes replayed))
         (divergences (consent-repl-stream--outcome-divergences
                       captured-outcomes replayed-outcomes 1 nil)))
    (list (consent-repl-stream--sym "repl-replay-report")
          (list (consent-repl-stream--sym "status")
                (consent-repl-stream--sym
                 (if divergences "diverged" "reproduced")))
          (list (consent-repl-stream--sym "submissions")
                (consent-repl-stream--int (length captured-outcomes)))
          (list (consent-repl-stream--sym "divergences") divergences))))

;;;; Shared chrome presentation

;;;###autoload
(defun consent-repl-stream-capture-from-string
    (input session chrome-name &optional apply-faces options input-echoed)
  "Drive a REPL over INPUT under SESSION and return the cons (CONTROL . PROGRAM-OUTPUT).
CONTROL is the painted control-channel text (records, plus -- under the `comment'
chrome -- its commented `;;   :: ' rendering of program output) and PROGRAM-OUTPUT
is the raw program-output stream, the two halves the live binary keeps on stderr
and stdout.  Under `comment' program output is in CONTROL (commented) and
PROGRAM-OUTPUT is empty; under every other chrome program output is raw in
PROGRAM-OUTPUT and CONTROL carries records only.  Faces are applied when
APPLY-FACES is non-nil.  INPUT-ECHOED models a host that already echoes
interaction input.  The Emacs twin of the portable `cli-repl-capture-from-string'."
  (let ((chrome (consent-repl-chrome-lookup chrome-name))
        (echo (consent-repl-chrome-output-formatter chrome-name session))
        (consent-repl-chrome-input-echoed input-echoed)
        (control nil)
        (program-output nil))
    (consent-repl-stream-run
     (consent-repl-stream--list-chunk-source
      (consent-repl-stream--split-lines input))
     (lambda (record)
       (let ((painted (consent-repl-chrome-paint
                       (funcall chrome record) apply-faces)))
         (when painted (push painted control))))
     ;; The `comment' chrome owns program output (commented, onto the control
     ;; channel); every other chrome leaves it raw on its own stream.
     (lambda (output)
       (let ((segments (funcall echo output)))
         (if segments
             (let ((painted (consent-repl-chrome-paint segments apply-faces)))
               (when painted (push painted control)))
           (push output program-output))))
     session options)
    (cons (apply #'concat (nreverse control))
          (apply #'concat (nreverse program-output)))))

;;;###autoload
(defun consent-repl-stream-rendered-from-string
    (input session chrome-name &optional apply-faces options input-echoed)
  "Drive a REPL over INPUT under SESSION and return the CHROME-NAME chrome's
control-channel text -- the full replayable transcript: records, plus -- under
the `comment' chrome -- its commented `;;   :: ' rendering of program output (which
`comment' owns).  The raw program-output stream is the cdr of
`consent-repl-stream-capture-from-string' and is dropped here.  Faces are applied
when APPLY-FACES is non-nil, so omitting it recovers the plain text.  INPUT-ECHOED
models a host that already echoes interaction input -- an interactive TTY -- so
the comment chrome suppresses its own submission echo.  This is the host-neutral,
buffer-free hook the chrome tests assert against, the Emacs twin of the portable
`cli-repl-rendered-from-string'."
  (car (consent-repl-stream-capture-from-string
        input session chrome-name apply-faces options input-echoed)))

;;;; Terminal/batch entry

(defun consent-repl-stream--batch-read-chunk ()
  "Read one line from batch stdin, returning it with a newline or the EOF sentinel."
  (condition-case nil
      (concat (read-from-minibuffer "") "\n")
    (error consent-repl-stream--eof)))

;;;###autoload
(defun consent-repl-stream-main ()
  "Batch entry point for the incremental Consent Scheme REPL.
Read forms incrementally from stdin, write each contract record to the error
stream and program output to stdout on separate channels, then exit Emacs with
the close-status code (0 for `closed-ok', 1 for `closed-error').  Intended to be
run under `emacs -Q --batch -l consent-repl-stream -f consent-repl-stream-main'."
  (let* ((session consent-repl-stream-default-session)
         (write-record
          (lambda (record)
            (princ (concat (consent-result->external record) "\n")
                   #'external-debugging-output)))
         (write-output
          (lambda (output) (princ output)))
         (exit-code
          (consent-repl-stream-run
           #'consent-repl-stream--batch-read-chunk
           write-record write-output session)))
    (kill-emacs exit-code)))

;;;###autoload
(defun consent-repl-stream-replay-main ()
  "Batch entry point: reload a captured transcript and replay it to a fresh session.
The transcript path is the first remaining command-line argument.  Replay its
complete submissions to a fresh `consent-repl-stream-default-session', write the
replayed contract record stream and the `repl-replay-report' to the error
stream, and exit Emacs with 0 when the replay reproduced the captured outcomes
or 1 when it diverged.  This is the Emacs parity twin of the portable shell's
`--replay FILE' mode.  Intended to be run under
`emacs -Q --batch -l consent-repl-stream -f consent-repl-stream-replay-main FILE'."
  (let ((path (car command-line-args-left))
        (session consent-repl-stream-default-session))
    (unless path
      (princ "consent-repl-stream-replay: missing transcript FILE\n"
             #'external-debugging-output)
      (kill-emacs 2))
    (let* ((text (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))
           (captured (consent-repl-stream-records-from-datum-stream text))
           (replayed (consent-repl-stream-replay-records captured session))
           (report (consent-repl-stream-replay-report captured replayed)))
      (dolist (record replayed)
        (princ (concat (consent-result->external record) "\n")
               #'external-debugging-output))
      (princ (concat (consent-result->external report) "\n")
             #'external-debugging-output)
      (kill-emacs
       (if (equal (consent-repl-stream--sym-name
                   (consent-repl-stream--field report "status"))
                  "reproduced")
           0 1)))))

;;;; Interactive command

(defconst consent-repl-stream-buffer-name "*Consent REPL Stream*"
  "Name of the buffer the interactive incremental REPL renders records into.")

;;;###autoload
(defun consent-repl-stream (source &optional session chrome-name)
  "Read and incrementally evaluate SOURCE in an incremental Consent Scheme REPL.
SOURCE may hold several forms; each is read and evaluated one at a time in the
durable SESSION (default `consent-repl-stream-default-session').  The emitted
contract records are rendered through the CHROME-NAME chrome (default
`comment', consistent with the portable terminal default) from
`consent-repl-chrome.el' -- realized as Emacs faces -- and appended to
`consent-repl-stream-buffer-name'.  `datum' recovers the canonical raw record
stream in the buffer.  Return the list of contract records.  Interactively,
prompt for SOURCE."
  (interactive
   (list (if (use-region-p)
             (buffer-substring-no-properties (region-beginning) (region-end))
           (read-string "Consent Scheme REPL input: "))))
  (let* ((session (or session consent-repl-stream-default-session))
         (chrome-name (or chrome-name (consent-repl-chrome-default-name)))
         (chrome (or (consent-repl-chrome-lookup chrome-name)
                     (consent-repl-chrome-lookup
                      (consent-repl-chrome-default-name))))
         (records (consent-repl-stream-records-from-string source session))
         (buffer (get-buffer-create consent-repl-stream-buffer-name)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (dolist (record records)
          (let ((painted (consent-repl-chrome-paint (funcall chrome record) t)))
            (when painted (insert painted)))))
      (special-mode))
    (when (called-interactively-p 'interactive)
      (display-buffer buffer))
    records))

(provide 'consent-repl-stream)

;;; consent-repl-stream.el ends here
