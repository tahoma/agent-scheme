;;; consent-repl-comint.el --- Live comint REPL buffer for Consent Scheme  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; A `comint-mode' surface onto a durable Consent Scheme session: a live,
;; editable prompt where you type a form, press RET, and see the chrome-rendered
;; result inline, with line editing, input history (`M-p'/`M-n'), kill/yank, and
;; a read-only prompt -- the terminal REPL's interactive feel brought to an Emacs
;; buffer.  It is the in-editor peer of the portable terminal REPL shell and of
;; the batch/scripted incremental entry `consent-repl-stream', not a replacement
;; for either, and it leaves every existing eval surface (`consent-repl-eval',
;; the read-only transcript/status/events buffers, the batch stream entry)
;; untouched.
;;
;; This buffer is *not* an island.  It evaluates over the same durable session
;; the other Emacs eval paths see: `consent-session-interaction-context'
;; (consent-eval.el) shares the session's live value and syntax environments, so
;; a `(define x 1)' typed here is visible to a later `C-c C-c'
;; (`consent-repl-eval') in the same session, and a definition or macro made
;; there is visible here.  Evaluation runs in-process through the shipped
;; substrate -- not a subprocess against the `consent' binary, which would
;; evaluate in a separate Scheme process -- so the buffer is a peer of the other
;; eval paths.
;;
;; The interaction is the cross-host REPL interaction contract
;; (docs/repl-interaction-contract.md), reusing the engine helpers in
;; `consent-repl-stream.el': one complete form is read at a time over the shared
;; recovery-aware reader, evaluated through `consent-interaction-eval-form', and
;; rendered as the contract's record vocabulary (`repl-prompt',
;; `repl-submission', `repl-result', `repl-condition', `repl-exit') through the
;; shared chrome model (`consent-repl-chrome.el', realized as Emacs faces).  The
;; default chrome is `comment', consistent with the portable terminal default and
;; with `consent-repl-stream'; the canonical `datum' chrome is always reachable
;; (`consent-repl-comint-set-chrome').  Because comint already echoes the typed
;; form, the chrome's input-echo signal (`consent-repl-chrome-input-echoed') is
;; bound on so the `comment' chrome suppresses its own submission echo -- this
;; buffer is exactly the "future echoing Emacs front end" that variable
;; anticipates.
;;
;; Incomplete forms are continued in place: when the typed input does not yet
;; parse to a complete form the buffer inserts a newline and shows the contract's
;; continuation gutter as a non-editable line prefix, keeping the form pending in
;; the editable input region; completing it then submits the whole form.
;;
;; The comint front end has no inferior Scheme process; following the IELM idiom,
;; a dummy `cat' process exists only to satisfy comint's process-buffer
;; machinery (markers, history, the read-only prompt) and never receives input or
;; evaluates anything.  All evaluation happens in this Emacs process over the
;; durable interaction context.

;;; Code:

(require 'comint)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-repl)
(require 'consent-repl-chrome)
(require 'consent-repl-stream)
(require 'consent-result)
(require 'consent-session)

(defgroup consent-repl-comint nil
  "Live comint REPL buffer for Consent Scheme."
  :group 'consent-repl)

(defcustom consent-repl-comint-default-session-id "repl-main"
  "Default durable session id a new live REPL buffer binds to.
This matches `consent-repl-default-named-session-id' so the live buffer and the
named `consent-repl-eval' surface inhabit the same session by default."
  :type 'string
  :group 'consent-repl-comint)

(defcustom consent-repl-comint-default-chrome 'comment
  "Default chrome name new live REPL buffers render records through.
`comment' matches the portable terminal default; `datum' recovers the canonical
record stream and is always reachable with `consent-repl-comint-set-chrome'."
  :type 'symbol
  :group 'consent-repl-comint)

(defcustom consent-repl-comint-prompt-read-only t
  "When non-nil, REPL prompts in the live buffer are read only.
This sets the buffer-local value of `comint-prompt-read-only'."
  :type 'boolean
  :group 'consent-repl-comint)

(defcustom consent-repl-comint-program-input-function
  #'consent-repl-comint--read-program-input-minibuffer
  "Function collecting one chunk of program input for a blocking read.
Called with no arguments when an evaluated form reads from the program input
port and the shared stdin cursor is exhausted.  It returns the next input chunk
as a string (a trailing newline is the read's line terminator) or nil at end of
stream.  The default reads a line from the minibuffer; a pre-seeded
`consent-repl-comint--input-queue' is drained first, so programmatic and test
callers never reach this function.  See docs/repl.md for the program-input
multiplexing model (#505)."
  :type 'function
  :group 'consent-repl-comint)

;;;; Buffer-local session and loop state

(defvar-local consent-repl-comint--session-id nil
  "Durable session id this live REPL buffer evaluates over.")

(defvar-local consent-repl-comint--interaction nil
  "Durable interaction context bridging this buffer to its session.")

(defvar-local consent-repl-comint--chrome nil
  "Active chrome name records render through in this buffer.")

(defvar-local consent-repl-comint--ordinal 1
  "One-based ordinal of the next submission in this session.")

(defvar-local consent-repl-comint--count 0
  "Number of submissions evaluated in this session.")

(defvar-local consent-repl-comint--closed nil
  "Non-nil once this session has emitted its `repl-exit' record.")

(defvar-local consent-repl-comint--input-queue nil
  "Pre-seeded program-input chunks drained before blocking for more input.
Each element is a string (with its own line terminator).  Programmatic and test
callers push onto this so an evaluated read consumes known input without a
minibuffer prompt.")

(defvar consent-repl-comint--input nil
  "Input string captured by `consent-repl-comint--input-sender'.
Dynamically bound by `consent-repl-comint-send-input' around `comint-send-input'
the same way IELM threads its input out of the comint sender.")

(defconst consent-repl-comint--prompt-regexp "^#| .*? |# "
  "Best-effort regexp matching the `comment' chrome's primary prompt.
Used for comint navigation and old-input recovery; the read-only prompt itself
is marked by `comint-output-filter' from the trailing prompt line, not this
regexp, so a non-`comment' chrome still gets read-only prompts.")

;;;; Process and rendering helpers

(defun consent-repl-comint--proc ()
  "Return this buffer's dummy comint process."
  (get-buffer-process (current-buffer)))

(defun consent-repl-comint--chrome-proc ()
  "Return the active chrome procedure, falling back to the default chrome."
  (or (consent-repl-chrome-lookup consent-repl-comint--chrome)
      (consent-repl-chrome-lookup (consent-repl-chrome-default-name))))

(defun consent-repl-comint--render-record (record)
  "Return RECORD painted through the active chrome, or the empty string.
Faces are applied; the submission echo is suppressed because comint already
echoes the typed form (`consent-repl-chrome-input-echoed' is bound on)."
  (let ((consent-repl-chrome-input-echoed t))
    (or (consent-repl-chrome-paint
         (funcall (consent-repl-comint--chrome-proc) record)
         t)
        "")))

(defun consent-repl-comint--render-output (text ordinal)
  "Return program-output TEXT for the live buffer (the single-stream transcript).
Under `comment' the chrome's output formatter yields the aligned `;;   :: ' echo
for ORDINAL's turn; under every other chrome the formatter yields nil, so TEXT is
inserted raw, exactly as a real REPL interleaves it."
  (let ((consent-repl-chrome-output-ordinal ordinal))
    (or (consent-repl-chrome-paint
         (funcall (consent-repl-chrome-output-formatter
                   (or consent-repl-comint--chrome
                       (consent-repl-chrome-default-name))
                   consent-repl-comint--session-id)
                  text)
         t)
        text)))

(defun consent-repl-comint--insert (string)
  "Insert STRING as comint output at the process mark.
The trailing line of STRING, if it does not end in a newline, becomes the
read-only prompt per `comint-output-filter'."
  (when (and string (> (length string) 0))
    (comint-output-filter (consent-repl-comint--proc) string)))

(defun consent-repl-comint--prompt-string (state &optional pending stack)
  "Return the painted prompt for STATE (\"ready\" or \"continuation\").
PENDING is the prompt's `pending' flag and STACK the reader open-construct stack
for a continuation prompt."
  (consent-repl-comint--render-record
   (consent-repl-stream--prompt-record
    consent-repl-comint--session-id consent-repl-comint--ordinal
    state pending stack)))

;;;; The per-submission driver (reuses the engine's record/reader helpers)

(defun consent-repl-comint--drive (buffer)
  "Process complete-form BUFFER one form at a time and return the rendered text.
BUFFER is interaction input terminated by a newline.  Each complete form emits a
`repl-submission' (echo-suppressed under `comment'), is evaluated through the
durable interaction context -- so definitions, imports, and macros persist and
are shared with the session -- and emits a `repl-result' or `repl-condition'.
An exit form emits a `repl-exit' and closes the session.  Program output written
during evaluation is interleaved before the form's result -- formatted through
the active chrome's output formatter, so `comment' renders it as the aligned
`;;   :: ' gutter and every other chrome leaves it raw -- and the shared stdin
cursor is seeded with the post-form program input so an evaluated read consumes
it (#505).  An incomplete trailing form (reached only on a forced send) is
reported as a recoverable unterminated-form read condition rather than swallowed.
Advances the ordinal/count as it goes."
  (let ((output "")
        (work buffer)
        (done nil))
    (while (and (not done) (not consent-repl-comint--closed))
      (pcase (consent-repl-stream--try-read work)
        (`(complete ,datum ,next)
         (let* ((source (string-trim (substring work 0 next)))
                (boundary (consent-repl-stream--submission-boundary work next))
                (program-input (substring work boundary)))
           (setq output
                 (concat output
                         (consent-repl-comint--render-record
                          (consent-repl-stream--submission-record
                           consent-repl-comint--session-id
                           consent-repl-comint--ordinal source t nil))))
           (if (consent-repl-stream--exit-form-p datum)
               (let ((disposition (consent-repl-stream--exit-disposition datum)))
                 (setq output
                       (concat output
                               (consent-repl-comint--render-record
                                (consent-repl-stream--exit-record
                                 consent-repl-comint--session-id "explicit"
                                 (car disposition)
                                 (1+ consent-repl-comint--count)
                                 (cdr disposition)))))
                 (setq consent-repl-comint--closed t)
                 (setq done t))
             (consent-interaction-seed-program-input!
              consent-repl-comint--interaction program-input)
             (let ((result (consent-interaction-eval-form
                            consent-repl-comint--interaction datum)))
               (let ((program-output (consent-interaction-program-output
                                      consent-repl-comint--interaction)))
                 (when (> (length program-output) 0)
                   (setq output
                         (concat output
                                 (consent-repl-comint--render-output
                                  program-output
                                  consent-repl-comint--ordinal)))))
               (setq output
                     (concat
                      output
                      (if (consent-repl-stream--error-result-p result)
                          (consent-repl-comint--render-record
                           (consent-repl-stream--condition-record
                            consent-repl-comint--session-id
                            consent-repl-comint--ordinal "eval" t
                            (consent-repl-stream--error-condition result)
                            (consent-repl-stream--error-message result)))
                        (consent-repl-comint--render-record
                         (consent-repl-stream--result-record
                          consent-repl-comint--session-id
                          consent-repl-comint--ordinal result
                          ;; Bound the result `display' the same way the stream
                          ;; engine does (#508); the live buffer applies the
                          ;; documented default ceiling.
                          (consent-repl-stream--result-display
                           result
                           consent-repl-stream-default-render-limits))))))
               (setq consent-repl-comint--ordinal
                     (1+ consent-repl-comint--ordinal))
               (setq consent-repl-comint--count
                     (1+ consent-repl-comint--count))
               (setq work
                     (or (consent-interaction-program-input-remainder
                          consent-repl-comint--interaction)
                         program-input))))))
        (`(malformed ,message ,next)
         (setq output
               (concat output
                       (consent-repl-comint--render-record
                        (consent-repl-stream--condition-record
                         consent-repl-comint--session-id
                         consent-repl-comint--ordinal "read" t
                         (consent-repl-stream--read-condition message)
                         message))))
         (setq work (substring work next))
         (setq consent-repl-comint--ordinal (1+ consent-repl-comint--ordinal)))
        (`(incomplete ,_stack)
         ;; The driver only reaches an incomplete form on a forced send (C-j),
         ;; since `consent-repl-comint-return' diverts a typed-but-incomplete
         ;; region to the continuation gutter before driving, or when a read
         ;; leaves a partial remainder.  Report it as a recoverable
         ;; unterminated-form read condition and resync, mirroring the engine's
         ;; report rather than silently swallowing the text.  The session stays
         ;; open (unlike the engine's EOF-mid-form, which also closes).
         (let ((source (string-trim work)))
           (setq output
                 (concat
                  output
                  (consent-repl-comint--render-record
                   (consent-repl-stream--submission-record
                    consent-repl-comint--session-id
                    consent-repl-comint--ordinal source nil nil))
                  (consent-repl-comint--render-record
                   (consent-repl-stream--condition-record
                    consent-repl-comint--session-id
                    consent-repl-comint--ordinal "read" t
                    (consent-repl-stream--read-condition
                     "unterminated form at end of input")
                    "unterminated form at end of input")))))
         (setq consent-repl-comint--ordinal (1+ consent-repl-comint--ordinal))
         (setq done t))
        (_                              ; empty: buffer consumed cleanly
         (setq done t))))
    output))

;;;; Input completeness (the continuation gate)

(defun consent-repl-comint--scan (buffer)
  "Scan BUFFER form by form and return (STATUS . STACK).
STATUS is `complete' when BUFFER ends cleanly (every form balanced, only
whitespace trailing) or holds a malformed datum the driver should report;
`incomplete' when the final form is an unbalanced prefix, with STACK the reader
open-construct stack (innermost first) for the continuation gutter."
  (let ((work buffer)
        (result nil))
    (while (not result)
      (pcase (consent-repl-stream--try-read work)
        (`(complete ,_datum ,next) (setq work (substring work next)))
        (`(incomplete ,stack) (setq result (cons 'incomplete stack)))
        (`(malformed ,_message ,_next) (setq result (cons 'complete nil)))
        (_ (setq result (cons 'complete nil)))))
    result))

;;;; Program input

(defun consent-repl-comint--read-program-input-minibuffer ()
  "Read one line of program input from the minibuffer.
Return the line with a trailing newline, or nil on `keyboard-quit' (EOF)."
  (condition-case nil
      (concat (read-string "Consent program input: ") "\n")
    (quit nil)))

(defun consent-repl-comint--program-input-reader (buffer)
  "Return a program-input reader thunk bound to live REPL BUFFER.
The thunk drains any pre-seeded `consent-repl-comint--input-queue' first, then
falls back to `consent-repl-comint-program-input-function' for a blocking read."
  (lambda ()
    (with-current-buffer buffer
      (if consent-repl-comint--input-queue
          (pop consent-repl-comint--input-queue)
        (funcall consent-repl-comint-program-input-function)))))

;;;; Commands

(defun consent-repl-comint--input-sender (_proc input)
  "Capture INPUT into `consent-repl-comint--input' for the send wrapper.
The dummy process never receives input; like IELM, this only threads the typed
text out of `comint-send-input'."
  (setq consent-repl-comint--input input))

(defun consent-repl-comint--evaluate (input)
  "Drive INPUT through the durable session, render its records, then re-prompt.
INPUT is the submitted form text without its terminating newline."
  (let ((output (consent-repl-comint--drive (concat input "\n"))))
    (consent-repl-comint--insert
     (if consent-repl-comint--closed
         output
       (concat output (consent-repl-comint--prompt-string "ready"))))))

(defun consent-repl-comint-send-input ()
  "Submit the current input and evaluate it, forcing a send.
Unlike `consent-repl-comint-return', this submits even an incomplete form: the
driver reports a recoverable unterminated-form read condition and resyncs rather
than waiting for the rest, mirroring a forced terminal send."
  (interactive)
  (if consent-repl-comint--closed
      (message "Consent REPL session %s is closed"
               consent-repl-comint--session-id)
    (let ((consent-repl-comint--input nil))
      (goto-char (point-max))
      ;; The continuation gutter rides on `line-prefix'/`wrap-prefix' display
      ;; properties of the editable region; strip them before `comint-send-input'
      ;; so they do not enter the input ring or the submission `source' text.
      (let ((inhibit-read-only t))
        (remove-text-properties
         (max (process-mark (consent-repl-comint--proc)) (point-min)) (point-max)
         '(line-prefix nil wrap-prefix nil)))
      (comint-send-input)
      (consent-repl-comint--evaluate (or consent-repl-comint--input "")))))

(defun consent-repl-comint--insert-continuation (stack)
  "Insert a newline and continuation gutter, keeping the pending form editable.
STACK is the reader open-construct stack used to render the gutter, shown as a
non-editable `line-prefix' so it never enters the submitted form text."
  (let ((gutter (consent-repl-comint--prompt-string "continuation" t stack)))
    (goto-char (point-max))
    (let ((start (point)))
      (insert "\n")
      (when (> (length gutter) 0)
        (add-text-properties start (point)
                             (list 'line-prefix gutter 'wrap-prefix gutter))))))

(defun consent-repl-comint-return ()
  "Evaluate the input form, or continue it when it is not yet complete.
A complete form (or a malformed one) is submitted and evaluated; an incomplete
form inserts a newline, shows the continuation gutter, and keeps the form
pending in the editable input region."
  (interactive)
  (if consent-repl-comint--closed
      (message "Consent REPL session %s is closed"
               consent-repl-comint--session-id)
    (let* ((pmark (process-mark (consent-repl-comint--proc)))
           (region (buffer-substring-no-properties
                    (max pmark (point-min)) (point-max))))
      (cond
       ;; A blank line just re-prompts in place rather than churning a no-op
       ;; submission that would draw a second prompt at the same ordinal.
       ((consent-repl-stream--blank-p region) (insert "\n"))
       (t (let ((scan (consent-repl-comint--scan (concat region "\n"))))
            (if (eq (car scan) 'incomplete)
                (consent-repl-comint--insert-continuation (cdr scan))
              (consent-repl-comint-send-input))))))))

(defun consent-repl-comint--close-eof-clean ()
  "Emit the clean EOF close record and mark the buffer closed."
  (setq consent-repl-comint--closed t)
  (consent-repl-comint--insert
   (consent-repl-comint--render-record
    (consent-repl-stream--exit-record
     consent-repl-comint--session-id "eof" "closed-ok"
     consent-repl-comint--count nil))))

(defun consent-repl-comint--close-eof-unterminated (source)
  "Emit the EOF-mid-form close: an unterminated read condition and closed-error.
SOURCE is the buffered partial form's text.  Mirrors the engine's EOF-incomplete
branch (`consent-repl-stream--engine'): a `(complete #f)(eof #t)' submission, a
non-recoverable `read'-phase condition, and a `closed-error' exit."
  (setq consent-repl-comint--closed t)
  (let ((detail "unterminated form at end of input"))
    (consent-repl-comint--insert
     (concat
      (consent-repl-comint--render-record
       (consent-repl-stream--submission-record
        consent-repl-comint--session-id consent-repl-comint--ordinal
        source nil t))
      (consent-repl-comint--render-record
       (consent-repl-stream--condition-record
        consent-repl-comint--session-id consent-repl-comint--ordinal "read" nil
        (consent-repl-stream--read-condition detail) detail))
      (consent-repl-comint--render-record
       (consent-repl-stream--exit-record
        consent-repl-comint--session-id "eof" "closed-error"
        consent-repl-comint--count detail))))))

(defun consent-repl-comint-send-eof ()
  "Close the session with an EOF close status without retiring it.
A clean EOF between forms closes `closed-ok'.  Any complete form still in the
input region is evaluated first; an unterminated partial form closes
`closed-error' with an unterminated-form read condition, matching the documented
EOF status and the engine twin.  The durable session persists for the other
Emacs eval paths; this buffer stops accepting submissions."
  (interactive)
  (if consent-repl-comint--closed
      (message "Consent REPL session %s is already closed"
               consent-repl-comint--session-id)
    (let* ((pmark (process-mark (consent-repl-comint--proc)))
           (region (buffer-substring-no-properties
                    (max pmark (point-min)) (point-max))))
      (if (consent-repl-stream--blank-p region)
          (consent-repl-comint--close-eof-clean)
        ;; Finalize the typed text as the final chunk, then close per its
        ;; completeness, exactly as the engine handles input ending mid-stream.
        (let ((consent-repl-comint--input nil))
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (remove-text-properties (max pmark (point-min)) (point-max)
                                    '(line-prefix nil wrap-prefix nil)))
          (comint-send-input)
          (let* ((input (or consent-repl-comint--input ""))
                 (buffer (concat input "\n")))
            (if (eq (car (consent-repl-comint--scan buffer)) 'incomplete)
                (consent-repl-comint--close-eof-unterminated (string-trim input))
              (let ((output (consent-repl-comint--drive buffer)))
                (unless consent-repl-comint--closed
                  (setq output
                        (concat output
                                (consent-repl-comint--render-record
                                 (consent-repl-stream--exit-record
                                  consent-repl-comint--session-id "eof"
                                  "closed-ok" consent-repl-comint--count nil))))
                  (setq consent-repl-comint--closed t))
                (consent-repl-comint--insert output)))))))
    (message "Consent REPL session %s closed" consent-repl-comint--session-id)))

(defun consent-repl-comint-set-chrome (name)
  "Set the active chrome to NAME for records rendered from now on.
Switching to `datum' recovers the canonical record stream in the buffer."
  (interactive
   (list (intern
          (completing-read
           "Consent REPL chrome: "
           (mapcar #'symbol-name (consent-repl-chrome-names))
           nil t nil nil
           (symbol-name (or consent-repl-comint--chrome
                            consent-repl-comint-default-chrome))))))
  (setq consent-repl-comint--chrome name)
  (message "Consent REPL chrome: %s" name))

;;;; Major mode and entry command

(defvar-keymap consent-repl-comint-mode-map
  :doc "Keymap for `consent-repl-comint-mode'."
  "RET"     #'consent-repl-comint-return
  "C-j"     #'consent-repl-comint-send-input
  "C-c C-d" #'consent-repl-comint-send-eof
  "C-c C-v" #'consent-repl-comint-set-chrome)

(define-derived-mode consent-repl-comint-mode comint-mode "Consent REPL"
  "Major mode for a live, interactive Consent Scheme REPL buffer.

Type a form at the prompt and press
\\<consent-repl-comint-mode-map>\\[consent-repl-comint-return] to evaluate it
in a durable session; the result renders inline through the active chrome.  An
incomplete form continues on a new line with a continuation gutter until it is
complete.

Definitions, imports, and macros persist across submissions and are shared with
the session the other Emacs eval paths (`consent-repl-eval') see.

\\[consent-repl-comint-send-input] forces a submission even when the form is incomplete.
\\[consent-repl-comint-send-eof] closes the session.
\\[consent-repl-comint-set-chrome] switches the rendering chrome (`datum'
recovers the raw records).

\\{consent-repl-comint-mode-map}"
  (setq-local comint-prompt-regexp consent-repl-comint--prompt-regexp)
  (setq-local comint-input-sender #'consent-repl-comint--input-sender)
  (setq-local comint-prompt-read-only consent-repl-comint-prompt-read-only)
  (setq-local comint-process-echoes nil)
  ;; Scheme program output may contain raw control characters; do not let comint
  ;; reinterpret them as carriage motion.
  (setq-local comint-inhibit-carriage-motion t)
  ;; Old-input recovery (history yank, mouse-2) uses comint's field-based
  ;; default, which works for any chrome since input/output regions carry comint
  ;; `field' properties -- no prompt-regexp coupling.
  (setq-local consent-repl-comint--chrome consent-repl-comint-default-chrome)
  (setq-local consent-repl-comint--ordinal 1)
  (setq-local consent-repl-comint--count 0)
  (setq-local consent-repl-comint--closed nil)
  (setq-local consent-repl-comint--input-queue nil)
  (setq-local mode-line-process
              '(:eval (if consent-repl-comint--closed " closed" " live")))
  ;; A dummy process keeps comint's markers, history, and read-only prompt
  ;; working; it never receives input and never evaluates anything (the IELM
  ;; idiom).  All evaluation is in-process over the durable interaction context.
  (unless (comint-check-proc (current-buffer))
    (start-process "consent-repl-comint" (current-buffer) "cat")
    (set-process-query-on-exit-flag (consent-repl-comint--proc) nil)
    (set-process-filter (consent-repl-comint--proc) #'comint-output-filter)))

(defun consent-repl-comint--ensure-session (id)
  "Return durable session ID, creating it as a named session when absent."
  (unless (consent-session-ref id)
    (consent-session-create! 'named (list :id id)))
  id)

(defun consent-repl-comint--init (id)
  "Bind this live REPL buffer to durable session ID and draw a prompt.
On a fresh buffer this builds the durable interaction context and draws the
first prompt.  On a live buffer it is a no-op.  On a buffer whose session was
closed (`consent-repl-comint-send-eof' or an exit form), it reopens the session
over the same context and draws a fresh prompt, so reissuing the command revives
it."
  (consent-repl-comint--ensure-session id)
  (setq-local consent-repl-comint--session-id id)
  (cond
   ((null consent-repl-comint--interaction)
    (setq-local consent-repl-comint--interaction
                (consent-session-interaction-context
                 id
                 (list :program-input-reader
                       (consent-repl-comint--program-input-reader
                        (current-buffer))
                       :capability-grants
                       (list consent-repl-stream--program-input-grant))))
    (consent-repl-comint--insert (consent-repl-comint--prompt-string "ready")))
   (consent-repl-comint--closed
    (setq consent-repl-comint--closed nil)
    (consent-repl-comint--insert (consent-repl-comint--prompt-string "ready")))))

(defun consent-repl-comint--buffer-name (id)
  "Return the live REPL buffer name for session ID."
  (format "*Consent REPL: %s*" id))

;;;###autoload
(defun consent-repl-comint (&optional session-id)
  "Open a live, interactive Consent Scheme REPL buffer for SESSION-ID.
The buffer presents an editable prompt bound to a durable session; typing a form
and pressing RET evaluates it in that session and renders the result inline,
with line editing, input history, and a read-only prompt from comint.  It shares
the session's definitions, imports, and macros with `consent-repl-eval' and the
other Emacs eval paths.

SESSION-ID defaults to the current native session (`consent-current-session-id')
when one is active, otherwise `consent-repl-comint-default-session-id'; the
session is created if it does not exist.  Interactively, a prefix argument
prompts for the session id.  Selecting a session also makes it the current
native session so `consent-repl-eval' targets the same one."
  (interactive
   (list (when current-prefix-arg
           (read-string
            "Consent REPL session: "
            (or consent-current-session-id
                consent-repl-comint-default-session-id)))))
  (let* ((id (or session-id
                 consent-current-session-id
                 consent-repl-comint-default-session-id))
         (buffer (get-buffer-create (consent-repl-comint--buffer-name id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'consent-repl-comint-mode)
        (consent-repl-comint-mode))
      (consent-repl-comint--init id))
    (setq consent-current-session-id id)
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(provide 'consent-repl-comint)

;;; consent-repl-comint.el ends here
