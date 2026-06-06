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
;;; roles** (`furniture', `prompt-session', `prompt-ordinal', `result-marker',
;;; `result-value', `error-marker', `error-text', `exit-status', and the neutral
;;; `submission' role for echoed source).  Roles -- never raw ANSI -- are the
;;; contract a host realizes, so the Emacs renderer (#425) can map the same model
;;; to faces.  The terminal substrate here maps roles to ANSI SGR through
;;; `cli-repl-chrome-paint'.
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
          cli-repl-chrome-paint
          cli-repl-chrome-color?)
  (import (scheme base)
          (scheme write))

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

    ;;;; The `comment' chrome (default): block-comment furniture, replayable

    (define (chrome--comment record)
      "Render RECORD under the default `comment' chrome.  Every prompt, result,
and diagnostic is a block comment and a complete submission is echoed as bare
source, so the whole control-channel stream is valid Consent Scheme that replays
to the same evaluation apart from program output."
      (let ((kind (chrome--kind record)))
        (cond
         ((eq? kind 'repl-prompt)
          (if (eq? (chrome--field record 'state) 'continuation)
              (list (chrome--furniture "#| ... |# "))
              (let ((session (chrome--field record 'session))
                    (ordinal (chrome--field record 'ordinal)))
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
          (if (chrome--field record 'complete)
              (list (chrome--seg 'submission (chrome--field record 'source))
                    (chrome--furniture "\n"))
              #f))
         ((eq? kind 'repl-result)
          (list (chrome--furniture "#| ")
                (chrome--seg 'result-marker "=> ")
                (chrome--seg 'result-value (chrome--display record))
                (chrome--furniture " |#\n")))
         ((eq? kind 'repl-condition)
          (list (chrome--furniture "#| ")
                (chrome--seg 'error-marker "!! ")
                (chrome--seg 'error-text (chrome--display record))
                (chrome--furniture " |#\n")))
         ((eq? kind 'repl-exit)
          (list (chrome--furniture "#| exit ")
                (chrome--seg 'exit-status
                            (symbol->string (or (chrome--field record 'status)
                                                'closed-ok)))
                (chrome--furniture " |#\n")))
         (else #f))))

    ;;;; The `datum' chrome: the canonical record stream, one datum per line

    (define (chrome--datum record)
      "Render RECORD as the canonical raw datum stream, one datum per line.
Returns a plain string, so the painter never colors it: the datum chrome is the
byte-for-byte raw record stream regardless of the color setting."
      (let ((port (open-output-string)))
        (write record port)
        (string-append (get-output-string port) "\n")))

    ;;;; The `classic' chrome: `>'/`|' prompts and bare values

    (define (chrome--classic record)
      "Render RECORD under the `classic' chrome: a `>'/`|' prompt and bare
values, with submissions and the exit record suppressed."
      (let ((kind (chrome--kind record)))
        (cond
         ((eq? kind 'repl-prompt)
          ;; `> ' and `| ' are both two columns wide, so a continued form's code
          ;; aligns under the first submission's code; `| ' reads as a
          ;; continuation gutter rule.
          (if (eq? (chrome--field record 'state) 'continuation)
              (list (chrome--furniture "| "))
              (list (chrome--furniture "> "))))
         ((eq? kind 'repl-result)
          (list (chrome--seg 'result-value (chrome--display record))
                (chrome--furniture "\n")))
         ((eq? kind 'repl-condition)
          (list (chrome--seg 'error-text (chrome--display record))
                (chrome--furniture "\n")))
         (else #f))))

    ;;;; The `quiet' chrome: no prompts; results and conditions only

    (define (chrome--quiet record)
      "Render RECORD under the `quiet' chrome: results and conditions only, with
prompts, submissions, and the exit record suppressed."
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
      "Render RECORD under the `silent' chrome: emit nothing for any record, so
only program output (carried by the shell on the program-output stream) reaches
the user."
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
      (let* ((symbol (if (string? name) (string->symbol name) name))
             (entry (assq symbol chrome--registry)))
        (and entry (cdr entry))))

    (define (cli-repl-chrome-names)
      "Return the list of registered chrome name symbols, in declaration order."
      (map car chrome--registry))

    (define (cli-repl-chrome-default-name)
      "Return the default chrome name."
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
       ((eq? role 'result-marker) "32")    ; green
       ((eq? role 'error-marker) "31")     ; red
       ((eq? role 'error-text) "31")       ; red
       ((eq? role 'exit-status) "33")      ; yellow
       (else #f)))                         ; result-value, submission, unknown

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
      "Render a chrome RESULT (#f, a string, or `(role . text)' segments) to a string or #f, applying ANSI SGR per role when COLOR? is true; a plain string is returned verbatim and never colored."
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
      "Return whether to colorize for MODE (`auto', `always', or `never').
`never' is always off and `always' is always on (an explicit override).  `auto'
colorizes only on a TTY with NO_COLOR unset, so output is plain when piped or
redirected: NO-COLOR? is #t when the NO_COLOR environment variable is set, and
TTY? is #t when the control channel is a terminal."
      (cond
       ((eq? mode 'never) #f)
       ((eq? mode 'always) #t)
       (else (and (not no-color?) tty? #t))))))
