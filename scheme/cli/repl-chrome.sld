;;; repl-chrome.sld --- Pluggable presentation chrome over the REPL record stream
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Host/core boundary: this library is the portable, host-neutral chrome layer
;;; that turns the cross-host REPL interaction contract record vocabulary
;;; (docs/repl-interaction-contract.md) into readable terminal output.  The raw
;;; record stream emitted by (cli repl-shell) is the canonical, machine-readable
;;; parity surface; chrome is host-specific *presentation* that rides above it.
;;;
;;; A chrome is a pure procedure `(render record) -> #f | <text> | <segments>'.
;;; `#f' suppresses the record; a string is emitted verbatim and never colored;
;;; a list of `(role . text)' segments expresses styling as named **semantic
;;; roles** (`furniture', `prompt-session', `prompt-ordinal', `prompt-nesting',
;;; `result-marker', `result-value', `error-marker', `error-text',
;;; `exit-marker', `exit-status', `output-marker', `output-text', and the
;;; neutral `submission' role for echoed source).
;;; Roles -- never raw ANSI -- are the
;;; contract a host realizes, so the Emacs renderer (#425) can map the same model
;;; to faces.  The terminal substrate here maps roles to ANSI SGR through
;;; `cli-repl-chrome-paint'.
;;;
;;; Program output is not a record: it rides its own stream.  Its presentation
;;; follows a per-chrome policy carried by `cli-repl-chrome-output-formatter'.
;;; The replayable `comment' chrome OWNS program output: the formatter renders
;;; each chunk as a commented (`;;   :: '), aligned line for the *control channel*
;;; where the records live, so a captured transcript replays the program output
;;; too and stdout stays clean.  Every other chrome's formatter returns #f, and
;;; the host wiring then leaves program output raw on stdout.  The engine stays
;;; chrome-agnostic; the host wiring routes the drained output to one stream or
;;; the other on that #f switch.
;;;
;;; The built-in chromes are ordinary registered procedures over records, not
;;; special-cased loop branches, so the explicit custom-chrome follow-up (#426)
;;; is additive rather than a redesign.  The `datum' chrome reproduces the raw
;;; record stream one datum per line and is always reachable, so the canonical
;;; surface is never suppressed by the active chrome.

(define-library (cli repl-chrome)
  (export cli-repl-chrome-lookup
          cli-repl-chrome-names
          cli-repl-chrome-default-name
          cli-repl-chrome-input-echoed?
          cli-repl-chrome-output-ordinal
          cli-repl-chrome-output-formatter
          cli-repl-chrome-paint
          cli-repl-chrome-color?)
  (import (scheme base)
          (scheme write)
          (only (consent reader)
                consent-datum->external
                consent-number-value))

  (begin

    ;;;; Record field access (the records are the shared cross-host vocabulary)

    (define (chrome--kind record)
      "Return RECORD's leading tag symbol, or #f when RECORD is not a record."
      (and (pair? record) (car record)))

    (define (chrome--field record name)
      "Return the single value of field NAME in tagged list RECORD, or #f."
      (let ((entry (assq name (cdr record))))
        (and entry (pair? (cdr entry)) (cadr entry))))

    (define (chrome--display record)
      "Return RECORD's human-readable `display' string, or the empty string."
      (or (chrome--field record 'display) ""))

    ;; The lone default session id, emitted when no `--session NAME' was given.
    ;; The `comment' chrome shows the ordinal alone for it and grows a session
    ;; label only for a named (non-default) session.
    (define chrome--default-session 'repl-main)

    (define (chrome--anonymous-session? session)
      "Return #t when SESSION is the lone default session id."
      (eq? session chrome--default-session))

    ;;;; Segment helpers

    (define (chrome--seg role text)
      "Build a `(role . text)' styling segment carrying TEXT under ROLE."
      (cons role text))

    (define (chrome--furniture text)
      "Build a neutral furniture segment carrying punctuation/whitespace TEXT."
      (chrome--seg 'furniture text))

    ;;;; Input-echo signal: does the host already echo interaction input?

    ;; On an interactive TTY the terminal driver echoes each typed form in cooked
    ;; mode, so the form is already on screen (and in any `script(1)' capture)
    ;; before the chrome runs.  The `comment' chrome keeps exactly one replayable
    ;; copy of each submission in the control-channel stream, so when the host
    ;; already echoes input it must *suppress* its own echo (the terminal's echo
    ;; is the single copy), and when input is piped or redirected -- no terminal
    ;; echo -- it must keep echoing (the chrome supplies the single copy).  This
    ;; parameter carries that host signal to the otherwise pure chrome without
    ;; handing it a live port: the shell binds it from a per-host TTY check
    ;; against stdin.  The default #f is the piped/redirected posture, so a
    ;; string-driven or scripted render echoes as before.
    (define cli-repl-chrome-input-echoed?
      (make-parameter #f))

    ;;;; Per-turn ordinal for program-output alignment

    ;; Program output is drained inside the loop, where the active form's ordinal
    ;; is known, but it reaches the chrome's output formatter outside that scope.
    ;; The shell binds this parameter to the current ordinal around each drain so
    ;; the `comment' chrome can right-align the `;;   :: ' output gutter to the
    ;; same column as that turn's result marker.  The default 1 is the
    ;; lone-default-session first-turn width.
    (define cli-repl-chrome-output-ordinal
      (make-parameter 1))

    ;;;; Comment-chrome alignment

    (define (chrome--field-integer record name default)
      "Return integer field NAME in RECORD as a host integer, or DEFAULT when absent."
      (let ((value (chrome--field record name)))
        (if value (consent-number-value value) default)))

    ;; The `comment' chrome right-aligns its result/condition/output/exit markers
    ;; and pads its continuation dots to the ready-prompt gutter, so a turn's
    ;; echoed form, printed output, and value all begin in the same column.  Both
    ;; widths derive from the prompt body -- the `<ordinal>' (lone default
    ;; session) or `<session>:<ordinal>' (named session) between the `#| ' and
    ;; ` |#' furniture.
    (define (chrome--comment-body-width session ordinal)
      "Character width of the comment prompt body for SESSION at ORDINAL: the"
      "`<ordinal>' digits alone, or `<session>:<ordinal>' for a named session."
      "The continuation gutter fills this width with dots so continued source"
      "aligns under the first line."
      (+ (if (chrome--anonymous-session? session)
             0
             (+ (string-length (symbol->string session)) 1))
         (string-length (number->string ordinal))))

    (define (chrome--comment-marker-pad session ordinal marker)
      "Return the `;;'-plus-spaces furniture that right-aligns MARKER (such as"
      "`=> ') to SESSION/ORDINAL's ready-prompt gutter width, so the text after"
      "MARKER starts in the same column as the echoed form.  At least one space"
      "follows `;;'."
      (let* ((gutter (+ 7 (chrome--comment-body-width session ordinal)))
             (pad (- gutter 2 (string-length marker))))
        (string-append ";;" (make-string (max 1 pad) #\space))))

    ;;;; The `comment' chrome (default): block-comment furniture, replayable

    (define (chrome--comment record)
      "Render RECORD under the default `comment' chrome.  The prompt is block-"
      "comment furniture; a complete submission is echoed as bare source; and"
      "each result, condition, exit, and line of program output is its own `;;'"
      "line comment whose marker right-aligns so the value, text, or printed"
      "output starts in the same column as the echoed form.  The whole"
      "transcript -- program output included -- is therefore valid Consent"
      "Scheme that replays to the same forms (program output is reformatted by"
      "`cli-repl-chrome-output-formatter', not rendered here).  The submission"
      "echo is suppressed when `cli-repl-chrome-input-echoed?' is true (the"
      "host -- an interactive TTY -- already echoes the typed form), so a"
      "captured transcript holds exactly one replayable copy of each form in"
      "both the piped and the interactive case."
      (let ((kind (chrome--kind record)))
        (cond
         ((eq? kind 'repl-prompt)
          (let ((session (chrome--field record 'session))
                (ordinal (chrome--field-integer record 'ordinal 1)))
            (if (eq? (chrome--field record 'state) 'continuation)
                ;; Width-matched alignment dots: a run of `.' exactly as wide as
                ;; the prompt body, so the gutter equals the ready-prompt width
                ;; and continued source aligns under the first line.  The
                ;; open-construct count is dropped here (it stays on the record
                ;; for the `datum' chrome).
                (list (chrome--furniture
                       (string-append
                        "#| "
                        (make-string
                         (chrome--comment-body-width session ordinal) #\.)
                        " |# ")))
                (append
                 (list (chrome--furniture "#| "))
                 (if (chrome--anonymous-session? session)
                     '()
                     (list (chrome--seg 'prompt-session (symbol->string session))
                           (chrome--furniture ":")))
                 (list (chrome--seg 'prompt-ordinal (number->string ordinal))
                       (chrome--furniture " |# "))))))
         ((eq? kind 'repl-submission)
          ;; Echo a whole form as bare code so it replays; leave an incomplete
          ;; (EOF-truncated) submission unechoed so the stream stays balanced.
          ;; When the host already echoes interaction input (an interactive TTY
          ;; in cooked mode), suppress this echo too: the terminal's own echo is
          ;; the single replayable copy, and a second copy would replay twice.
          (if (and (chrome--field record 'complete)
                   (not (cli-repl-chrome-input-echoed?)))
              (list (chrome--seg 'submission (chrome--field record 'source))
                    (chrome--furniture "\n"))
              #f))
         ((eq? kind 'repl-result)
          ;; A `;;'-aligned line comment, then a `;;' blank separator line.
          (let ((session (chrome--field record 'session))
                (ordinal (chrome--field-integer record 'ordinal 1)))
            (list (chrome--furniture
                   (chrome--comment-marker-pad session ordinal "=> "))
                  (chrome--seg 'result-marker "=> ")
                  (chrome--seg 'result-value (chrome--display record))
                  (chrome--furniture "\n;;\n"))))
         ((eq? kind 'repl-condition)
          (let ((session (chrome--field record 'session))
                (ordinal (chrome--field-integer record 'ordinal 1)))
            (list (chrome--furniture
                   (chrome--comment-marker-pad session ordinal "!! "))
                  (chrome--seg 'error-marker "!! ")
                  (chrome--seg 'error-text (chrome--display record))
                  (chrome--furniture "\n;;\n"))))
         ((eq? kind 'repl-exit)
          ;; The exit line aligns from the close `count' and carries no trailing
          ;; separator.
          (let ((session (chrome--field record 'session))
                (count (chrome--field-integer record 'count 1)))
            (list (chrome--furniture
                   (chrome--comment-marker-pad session count "__ "))
                  (chrome--seg 'exit-marker "__ ")
                  (chrome--furniture "exit ")
                  (chrome--seg 'exit-status
                              (symbol->string (or (chrome--field record 'status)
                                                  'closed-ok)))
                  (chrome--furniture "\n"))))
         (else #f))))

    ;;;; Program-output formatting (the `comment' chrome's `;;   :: ' gutter)

    (define (chrome--split-output-lines text)
      "Split program-output TEXT into its lines for per-line comment rendering,"
      "dropping the empty tail a trailing newline produces so `(display"
      "\"x\\n\")' yields exactly one line and a line lacking a trailing newline"
      "still renders."
      (let ((length (string-length text)))
        (let loop ((start 0) (index 0) (lines '()))
          (cond
           ((>= index length)
            (reverse (if (> index start)
                         (cons (substring text start index) lines)
                         lines)))
           ((char=? (string-ref text index) #\newline)
            (loop (+ index 1) (+ index 1)
                  (cons (substring text start index) lines)))
           (else (loop start (+ index 1) lines))))))

    (define (chrome--comment-output text session ordinal)
      "Render program-output TEXT as `;;   :: ' comment-line segments aligned"
      "to SESSION/ORDINAL's gutter -- one comment line per output line, each"
      "newline-terminated so the comment closes before the following result"
      "line.  Empty TEXT yields no segments."
      (let ((pad (chrome--comment-marker-pad session ordinal ":: ")))
        (let loop ((lines (chrome--split-output-lines text)) (segments '()))
          (if (null? lines)
              (reverse segments)
              (loop (cdr lines)
                    (cons (chrome--furniture "\n")
                          (cons (chrome--seg 'output-text (car lines))
                                (cons (chrome--seg 'output-marker ":: ")
                                      (cons (chrome--furniture pad)
                                            segments)))))))))

    (define (cli-repl-chrome-output-formatter name session)
      "Return chrome NAME's program-output formatter bound to SESSION: a"
      "procedure mapping one program-output chunk to control-channel painter"
      "input, or #f when the chrome keeps program output raw on its own stream."
      "The replayable `comment' chrome OWNS program output -- this returns its"
      "`;;   :: ' rendering, aligned to SESSION and the per-turn"
      "`cli-repl-chrome-output-ordinal', for the control channel (where the"
      "records live), so a captured transcript replays the output and stdout"
      "stays clean.  Every other chrome returns #f, so the host wiring leaves"
      "program output raw on stdout.  The #f is the switch between the two"
      "streams."
      #((parameters
         (name
          (type symbol)
          (description
           ("Chrome name as a symbol or string, looked up against the"
             "registry.")))
         (session
          (type symbol)
          (description
           ("Session id as a symbol or string, used to align the output"
             "gutter."))))
        (returns
         (type procedure)
         (description
          ("A one-argument procedure mapping a program-output chunk to"
            "control-channel painter input for the `comment' chrome, or"
            "to #f for every other chrome.")))
        (effects allocation))
      (let ((symbol (if (string? name) (string->symbol name) name))
            (session-symbol (if (string? session)
                                (string->symbol session)
                                session)))
        (if (eq? symbol 'comment)
            (lambda (text)
              (chrome--comment-output
               text session-symbol (cli-repl-chrome-output-ordinal)))
            (lambda (text) #f))))

    ;;;; The `datum' chrome: the canonical record stream, one datum per line

    (define (chrome--datum record)
      "Render RECORD as the canonical raw datum stream, one datum per line."
      "Returns a plain string, so the painter never colors it: the datum chrome"
      "is the byte-for-byte raw record stream regardless of the color setting."
      "The consent writer renders it so canonical number records inside the"
      "contract data come out Scheme-readable (the Emacs twin renders its"
      "stream the same way)."
      (string-append (consent-datum->external record) "\n"))

    ;;;; The `classic' chrome: `>'/`.' prompts and marked values

    (define (chrome--classic record)
      "Render RECORD under the `classic' chrome: a familiar terminal-REPL look"
      "with a `> ' prompt, a `. ' continuation gutter, the whole form echoed as"
      "bare source (TTY-gated like the `comment' chrome), and single-column"
      "`= '/`! '/`_ ' markers on the value, condition, and exit lines.  Unlike"
      "`comment', `classic' makes no replay claim -- its bare marked lines are"
      "not Scheme -- so program output stays raw and interleaved, exactly as a"
      "real REPL shows it; the markers earn their keep instead by"
      "disambiguating result, condition, and program output in a colorless"
      "capture."
      (let ((kind (chrome--kind record)))
        (cond
         ((eq? kind 'repl-prompt)
          ;; `> ' and `. ' are both two columns wide, so a continued form's code
          ;; aligns under the first submission's code; `. ' reads as a clean
          ;; continuation gutter.  The open-construct count is dropped (it stays
          ;; on the record for the `datum' chrome).
          (if (eq? (chrome--field record 'state) 'continuation)
              (list (chrome--furniture ". "))
              (list (chrome--furniture "> "))))
         ((eq? kind 'repl-submission)
          ;; Echo the whole form as bare source after `> ', so a piped or
          ;; captured session shows the forms; suppress it when the host already
          ;; echoes input (#447), so a live TTY does not double-echo.
          (if (and (chrome--field record 'complete)
                   (not (cli-repl-chrome-input-echoed?)))
              (list (chrome--seg 'submission (chrome--field record 'source))
                    (chrome--furniture "\n"))
              #f))
         ((eq? kind 'repl-result)
          (list (chrome--seg 'result-marker "= ")
                (chrome--seg 'result-value (chrome--display record))
                (chrome--furniture "\n\n")))
         ((eq? kind 'repl-condition)
          ;; `! ' (not `- ') so an error pops in a colorless capture and rhymes
          ;; with the `comment' chrome's `!! '.
          (list (chrome--seg 'error-marker "! ")
                (chrome--seg 'error-text (chrome--display record))
                (chrome--furniture "\n\n")))
         ((eq? kind 'repl-exit)
          (list (chrome--seg 'exit-marker "_ ")
                (chrome--furniture "exit ")
                (chrome--seg 'exit-status
                            (symbol->string (or (chrome--field record 'status)
                                                'closed-ok)))
                (chrome--furniture "\n")))
         (else #f))))

    ;;;; The `quiet' chrome: no prompts; results and conditions only

    (define (chrome--quiet record)
      "Render RECORD under the `quiet' chrome: results and conditions only,"
      "with prompts, submissions, and the exit record suppressed."
      (let ((kind (chrome--kind record)))
        (cond
         ((eq? kind 'repl-result)
          (list (chrome--seg 'result-value (chrome--display record))
                (chrome--furniture "\n")))
         ((eq? kind 'repl-condition)
          (list (chrome--seg 'error-text (chrome--display record))
                (chrome--furniture "\n")))
         (else #f))))

    ;;;; The `silent' chrome: suppress every interaction record

    (define (chrome--silent record)
      "Render RECORD under the `silent' chrome: emit nothing for any record, so"
      "only program output (carried by the shell on the program-output stream)"
      "reaches the user."
      (and record #f))

    ;;;; Chrome registry

    ;; Built-in chromes are ordinary registered procedures over records.  A
    ;; future custom chrome (#426) is the same kind of value, so it slots in
    ;; here without changing the loop or the painter.
    (define chrome--registry
      (list (cons 'comment chrome--comment)
            (cons 'datum chrome--datum)
            (cons 'classic chrome--classic)
            (cons 'quiet chrome--quiet)
            (cons 'silent chrome--silent)))

    (define (cli-repl-chrome-lookup name)
      "Return the chrome procedure registered under NAME (a symbol or string), or #f."
      #((parameters
         (name
          (type symbol)
          (description
           ("Chrome name as a symbol or string to resolve against the"
             "registry."))))
        (returns
         (type (or procedure boolean))
         (description
          ("The render procedure registered under NAME, or #f when no"
            "chrome matches.")))
        (effects state-read))
      (let* ((symbol (if (string? name) (string->symbol name) name))
             (entry (assq symbol chrome--registry)))
        (and entry (cdr entry))))

    (define (cli-repl-chrome-names)
      "Return the list of registered chrome name symbols, in declaration order."
      #((parameters)
        (returns
         (type symbol)
         (description
          ("A freshly allocated list of the registered chrome name"
            "symbols, in declaration order.")))
        (effects state-read allocation))
      (map car chrome--registry))

    (define (cli-repl-chrome-default-name)
      "Return the default chrome name."
      #((parameters)
        (returns
         (type symbol)
         (description ("The symbol `comment', the name of the default chrome.")))
        (effects pure))
      'comment)

    ;;;; Terminal substrate: roles to ANSI SGR

    ;; ANSI SGR escape introducer, built without a literal escape in source.
    (define chrome--escape (string (integer->char 27)))

    (define (chrome--role-sgr role)
      "Return the SGR parameter string for ROLE, or #f for an uncolored role."
      (cond
       ((eq? role 'furniture) "90")        ; bright black / gray punctuation
       ((eq? role 'prompt-session) "36")   ; cyan
       ((eq? role 'prompt-ordinal) "34")   ; blue
       ((eq? role 'prompt-nesting) "35")   ; magenta
       ((eq? role 'result-marker) "32")    ; green
       ((eq? role 'error-marker) "31")     ; red
       ((eq? role 'error-text) "31")       ; red
       ((eq? role 'exit-marker) "33")      ; yellow, matching exit-status
       ((eq? role 'exit-status) "33")      ; yellow
       ((eq? role 'output-marker) "90")    ; gray gutter, like the `;;' furniture
       ; result-value, submission, output-text, unknown
       (else #f)))

    (define (chrome--wrap code text)
      "Wrap TEXT in the SGR escape for CODE, resetting afterward."
      (string-append chrome--escape "[" code "m" text chrome--escape "[0m"))

    (define (chrome--segment->string segment color?)
      "Render one `(role . text)' SEGMENT, applying SGR when COLOR? is true."
      (let ((role (car segment))
            (text (cdr segment)))
        (if color?
            (let ((code (chrome--role-sgr role)))
              (if code (chrome--wrap code text) text))
            text)))

    (define (cli-repl-chrome-paint result color?)
      "Render a chrome RESULT (#f, a string, or `(role . text)' segments)"
      "to a string or #f, applying ANSI SGR per role when COLOR? is true; a"
      "plain string is returned verbatim and never colored."
      #((parameters
         (result
          (type (or string list boolean))
          (description
           ("A chrome result: #f, a verbatim string, or a list of"
             "`(role . text)' segments.")))
         (color?
          (type boolean)
          (description
           ("When #t, wrap colorable segments in ANSI SGR escapes by"
             "their role."))))
        (returns
         (type (or string boolean))
         (description
          ("#f when RESULT is #f, the string unchanged when RESULT is"
            "a string, otherwise the concatenated segment text with"
            "per-role SGR applied when COLOR? is true.")))
        (effects allocation))
      (cond
       ((not result) #f)
       ((string? result) result)
       (else
        (let loop ((segments result) (accumulated ""))
          (if (null? segments)
              accumulated
              (loop (cdr segments)
                    (string-append
                     accumulated
                     (chrome--segment->string (car segments) color?))))))))

    ;;;; Color decision

    (define (cli-repl-chrome-color? mode no-color? tty?)
      "Return whether to colorize for MODE (`auto', `always', or `never')."
      "`never' is always off and `always' is always on (an explicit override)."
      "`auto' colorizes only on a TTY with NO_COLOR unset, so output is plain"
      "when piped or redirected: NO-COLOR? is #t when the NO_COLOR environment"
      "variable is set, and TTY? is #t when the control channel is a terminal."
      #((parameters
         (mode
          (type symbol)
          (description "Color mode symbol: `auto', `always', or `never'."))
         (no-color?
          (type boolean)
          (description
           ("#t when the NO_COLOR environment variable is set, forcing"
             "plain output under `auto'.")))
         (tty?
          (type boolean)
          (description
           ("#t when the control channel is a terminal, enabling color"
             "under `auto'."))))
        (returns . "#t to colorize output, #f to leave it plain.")
        (effects pure))
      (cond
       ((eq? mode 'never) #f)
       ((eq? mode 'always) #t)
       (else (and (not no-color?) tty? #t))))))
