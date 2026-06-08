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

(defun consent-repl-stream--prompt-record (session ordinal state pending)
  "Build a `repl-prompt' record for SESSION at ORDINAL with STATE and PENDING."
  (list (consent-repl-stream--sym "repl-prompt")
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
        (list (consent-repl-stream--sym "ordinal")
              (consent-repl-stream--int ordinal))
        (list (consent-repl-stream--sym "state")
              (consent-repl-stream--sym state))
        (list (consent-repl-stream--sym "pending")
              (consent-repl-stream--bool pending))))

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
  "Build a `repl-result' record wrapping EVALUATION-RESULT and DISPLAY at ORDINAL."
  (list (consent-repl-stream--sym "repl-result")
        (list (consent-repl-stream--sym "id")
              (consent-repl-stream--tag "res" ordinal))
        (list (consent-repl-stream--sym "submission")
              (consent-repl-stream--tag "sub" ordinal))
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
        (list (consent-repl-stream--sym "evaluation-result") evaluation-result)
        (list (consent-repl-stream--sym "display") display)))

(defun consent-repl-stream--condition-record
    (session ordinal phase recoverable condition display)
  "Build a `repl-condition' record for PHASE/RECOVERABLE CONDITION at ORDINAL."
  (list (consent-repl-stream--sym "repl-condition")
        (list (consent-repl-stream--sym "id")
              (consent-repl-stream--tag "cond" ordinal))
        (list (consent-repl-stream--sym "submission")
              (consent-repl-stream--tag "sub" ordinal))
        (list (consent-repl-stream--sym "session")
              (consent-repl-stream--session-field session))
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
Return one of (complete DATUM NEXT), (empty), (incomplete), or
(malformed MESSAGE NEXT)."
  (let ((step (consent-read-recover-from-string-at buffer 0)))
    (pcase (consent-recovery-step-status step)
      ('datum
       (list 'complete
             (consent-recovery-step-datum step)
             (consent-recovery-step-next step)))
      ('eof (list 'empty))
      ('incomplete (list 'incomplete))
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
         (interaction
          (consent-make-interaction-context
           (append (list :session-id session-id) options)))
         (exit-code 0))
    (cl-labels
        ((emit (record)
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
         (drain-output! ()
           (let ((output (consent-interaction-program-output interaction)))
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
                (let ((chunk (next-chunk)))
                  (if (eof-chunk-p chunk)
                      (if (consent-repl-stream--blank-p buffer)
                          (list 'eof nil buffer)
                        (list 'eof-incomplete buffer buffer))
                    (progn
                      (emit (consent-repl-stream--prompt-record
                             session ordinal "continuation" t))
                      (acquire (concat buffer chunk) ordinal)))))))))
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
                      (rest (substring current next)))
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
                   (let ((result (consent-interaction-eval-form
                                  interaction datum)))
                     (drain-output!)
                     (if (consent-repl-stream--error-result-p result)
                         (emit (consent-repl-stream--condition-record
                                session ordinal "eval" t
                                (consent-repl-stream--error-condition result)
                                (consent-repl-stream--error-message result)))
                       (emit (consent-repl-stream--result-record
                              session ordinal result
                              (consent-repl-stream--result-display result))))
                     (setq buffer rest)
                     (setq ordinal (1+ ordinal))
                     (setq count (1+ count)))))))))))
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

;;;; Shared chrome presentation

;;;###autoload
(defun consent-repl-stream-rendered-from-string
    (input session chrome-name &optional apply-faces options input-echoed)
  "Drive a REPL over INPUT under SESSION and return the CHROME-NAME chrome's text.
Each contract record is rendered through the named chrome from
`consent-repl-chrome.el' and concatenated into the control-channel text;
program output is discarded.  Faces are applied when APPLY-FACES is non-nil, so
omitting it recovers the plain text.  INPUT-ECHOED models a host that already
echoes interaction input -- an interactive TTY -- so the comment chrome
suppresses its own submission echo.  This is the host-neutral, buffer-free hook
the chrome tests assert against, the Emacs twin of the portable
`cli-repl-rendered-from-string'."
  (let ((chrome (consent-repl-chrome-lookup chrome-name))
        (consent-repl-chrome-input-echoed input-echoed)
        (parts nil))
    (consent-repl-stream-run
     (consent-repl-stream--list-chunk-source
      (consent-repl-stream--split-lines input))
     (lambda (record)
       (let ((painted (consent-repl-chrome-paint
                       (funcall chrome record) apply-faces)))
         (when painted (push painted parts))))
     #'ignore
     session options)
    (apply #'concat (nreverse parts))))

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
