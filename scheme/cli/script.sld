;;; script.sld --- Shebang handling for executable Consent Scheme scripts
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Host/core boundary: this library is the portable, host-neutral half of the
;;; executable-script support (docs/executable-scripts.md).  It is the
;;; non-interactive twin of the terminal REPL shell (cli repl-shell): where the
;;; REPL reads interaction input from a terminal, a script is an ordinary
;;; Consent Scheme source file that a `#!' line marks executable so the shell can
;;; run it directly.
;;;
;;; `#!' is not free in Scheme: it prefixes reader directives (`#!fold-case'),
;;; version flags (`#!r6rs'), named values (`#!eof'), and DSSSL keywords
;;; (`#!optional').  So a shebang is recognized only NARROWLY -- a `#!' that is
;;; the first two bytes of the source followed by `/' or whitespace -- and is
;;; consumed here, at the script-loading boundary, before the source reaches the
;;; reader.  The reader's directive handling is left untouched, so `#!fold-case'
;;; and every other `#!'-token keep their normal token meaning everywhere else.
;;;
;;; The strip preserves the line terminator that ended the shebang line, so the
;;; first line of the remaining source is blank rather than removed.  Datum line
;;; numbers therefore match the original file, keeping reader and evaluator
;;; diagnostics aligned with what the author sees on disk.

(define-library (cli script)
  (export cli-script-shebang-line?
          cli-script-strip-shebang
          cli-script-source-from-file
          cli-script-run-file
          cli-script-host-run-options
          cli-script-host-run-file)
  (import (scheme base)
          (scheme file)
          (consent eval)
          (only (consent reader) consent-read-all))

  (begin

    (define (script--whitespace-after-bang? char)
      "Return #t when CHAR (`/' or intertoken whitespace) may follow `#!'"
      "to introduce a shebang; `#!fold-case' and other letter-led"
      "`#!'-tokens are excluded."
      (or (char=? char #\/)
          (char=? char #\space)
          (char=? char #\tab)))

    (define (cli-script-shebang-line? source)
      "Return #t when SOURCE begins with an executable-script shebang:"
      "`#!' as the first two characters followed by `/' or whitespace,"
      "narrow enough to leave `#!fold-case' and other `#!'-tokens alone."
      #((parameters
         (source
          (type any)
          (description
           ("Script source text to inspect for a leading shebang."))))
        (returns
         (type any)
         (description
          ("#t when SOURCE opens with a `#!' followed by `/' or"
           "whitespace, else #f.")))
        (effects pure))
      (and (>= (string-length source) 3)
           (char=? (string-ref source 0) #\#)
           (char=? (string-ref source 1) #\!)
           (script--whitespace-after-bang? (string-ref source 2))))

    (define (script--line-terminator-index source)
      "Return the index of the first newline in SOURCE, or its length when none."
      (let ((length (string-length source)))
        (let loop ((index 0))
          (cond
           ((>= index length) length)
           ((char=? (string-ref source index) #\newline) index)
           (else (loop (+ index 1)))))))

    (define (cli-script-strip-shebang source)
      "Return SOURCE with a leading shebang line removed up to (not"
      "including) its newline, so the remaining source keeps a blank first"
      "line and later datums keep their line numbers; SOURCE without a"
      "shebang is returned unchanged for the reader."
      #((parameters
         (source
          (type any)
          (description
           ("Script source text whose leading shebang line, if any, is"
            "removed."))))
        (returns
         (type any)
         (description
          ("SOURCE with the shebang stripped up to its newline, or"
           "SOURCE unchanged when none is present.")))
        (effects allocation))
      (if (cli-script-shebang-line? source)
          (substring source
                     (script--line-terminator-index source)
                     (string-length source))
          source))

    (define (script--read-file-string path)
      "Return the contents of PATH as a string."
      (call-with-input-file path
        (lambda (port)
          (let loop ((chars '()))
            (let ((char (read-char port)))
              (if (eof-object? char)
                  (list->string (reverse chars))
                  (loop (cons char chars))))))))

    (define (cli-script-source-from-file path)
      "Return PATH's contents with any leading executable-script shebang"
      "removed, ready for the reader."
      #((parameters
         (path
          (type any)
          (description "Filesystem path of the script file to read.")))
        (returns
         (type any)
         (description
          ("The file's contents as a string with any leading shebang"
           "line stripped.")))
        (effects state-read allocation error))
      (cli-script-strip-shebang (script--read-file-string path)))

    (define (script--rest-environment rest)
      "Return the optional evaluation environment from REST."
      (if (null? rest) #f (car rest)))

    (define (script--rest-options rest)
      "Return the optional evaluation options from REST."
      (if (or (null? rest) (null? (cdr rest)))
          '()
          (cadr rest)))

    (define (script--option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT when KEY is absent."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (script--options-with-command-line path options)
      "Return OPTIONS with PATH and script arguments as command-line."
      (cons (cons 'command-line
                  (cons path
                        (script--option-ref options
                                            'script-arguments
                                            '())))
            options))

    (define (cli-script-run-file path . rest)
      "Run executable Consent Scheme script PATH through the Consent"
      "interpreter and return its last value."
      "A leading shebang line is consumed before reading, so a file made"
      "executable with `#!/usr/bin/env consent' (or the `/bin/sh'"
      "polyglot) reads correctly. Evaluation goes through"
      "`consent-eval-source' with the optional REST (environment,"
      "options). Ambient host capabilities -- opening a named file, a"
      "process, network -- fail closed without an explicit grant, policy"
      "file, or preloaded approval, and a denial or error raises so a CLI"
      "caller exits non-zero. The standard streams are consented by"
      "invocation: when REST's options supply the host stream devices"
      "(`program-input-reader', `program-output-writer',"
      "`program-error-writer') with one matching `port' grant per stream,"
      "the script reads stdin and writes stdout/stderr"
      "(docs/repl-interaction-contract.md, \"Program Stream Model\"); the"
      "product main attaches these by default so a"
      "`(read-line)'/`(display ...)' filter works in a pipe, streaming"
      "incrementally. The standard `(command-line)' value is PATH followed by"
      "any `script-arguments' option supplied by the host entrypoint, without"
      "granting ambient host process access. Finite in-memory input uses a"
      "reader built with"
      "`consent-program-input-from-string'. This is the host-neutral peer"
      "of the Emacs `consent-script-run-file'."
      #((parameters
         (path
          (type any)
          (description
           ("Filesystem path of the executable Consent Scheme script to"
            "run.")))
         (rest
          (type any)
          (description
           ("Optional evaluation arguments forwarded to"
            "`consent-eval-source' (environment, options)."))))
        (returns
         (type any)
         (description
          ("The last value produced by evaluating the script's source.")))
        (effects state-read host-eval error))
      (consent-eval-source
       (cli-script-source-from-file path)
       (script--rest-environment rest)
       (script--options-with-command-line path
                                         (script--rest-options rest))))

    ;; Host-runner posture: the deliberate capability bundle that lets the
    ;; compiled runtime act as a Consent-Scheme host runner for portable test
    ;; programs. It grants access to the runtime's own internal libraries and
    ;; raises the per-run budgets so a test file that drives the runtime hard
    ;; can complete. Program output is captured per form through the interaction
    ;; context rather than written to a raw host port, so the host runner stays
    ;; inside the capability model.
    (define cli-script-host-run-base-options
      '((internal-libraries-allowed . #t)
        (max-steps . 1000000000)
        (max-host-callbacks . 1000000000)
        (max-events . 1000000000)
        (max-event-nodes . 1000000000)
        (max-value-nodes . 1000000000)
        (max-interned-symbols . 1000000000)))

    (define (cli-script-host-run-options root)
      "Return the host-run capability options rooted at absolute directory"
      "ROOT.  ROOT becomes the include directory and the sole file-access"
      "root, so a host runner reads fixtures and writes scratch files only"
      "under that working-tree subtree. The file capability system matches by"
      "absolute path containment, so ROOT must be absolute. First-class"
      "(persisted) capability grants are used rather than the transient legacy"
      "file-paths allow-list so that port handles opened by"
      "`call-with-input-file' and friends revalidate against an active grant"
      "on every read/write rather than failing closed mid-stream. A"
      "process-environment grant is included so a host-runner test can read"
      "its CI configuration from the host environment; that capability remains"
      "denied to ordinary scripts."
      #((parameters
         (root
          (type any)
          (description
           ("Absolute directory the host run is scoped to; becomes the"
            "include directory and sole file-access root."))))
        (returns
         (type any)
         (description
          ("An options alist of include-directory, capability grants,"
           "and raised per-run budgets for the host runner.")))
        (effects allocation))
      (cons (cons 'include-directory root)
            (cons (list 'capability-grants
                        (list 'capability-grant
                              (list 'id 'host-run-file-grant)
                              (list 'domain 'file)
                              (cons 'operations
                                    '(read create write metadata delete load))
                              (list 'scope
                                    (list 'file-root root)
                                    (list 'paths (list "."))
                                    (list 'remote 'denied)
                                    (list 'symlinks 'resolve-within-root))
                              (list 'expires 'never))
                        (list 'capability-grant
                              (list 'id 'host-run-process-environment-grant)
                              (list 'domain 'process-environment)
                              (cons 'operations '(read))
                              (list 'expires 'never))
                        ;; Host-runner tests time their checks through
                        ;; (scheme time), so the bundle grants clock reads.
                        (list 'capability-grant
                              (list 'id 'host-run-clock-grant)
                              (list 'domain 'clock)
                              (cons 'operations
                                    '(current-second
                                      current-jiffy
                                      jiffies-per-second))
                              (list 'expires 'never)))
                  cli-script-host-run-base-options)))

    (define (script--result-field datum name)
      "Return the single value of field NAME in tagged-list DATUM, or #f."
      (let ((entry (assq name (cdr datum))))
        (and entry (pair? (cdr entry)) (cadr entry))))

    (define (cli-script-host-run-file path root emit)
      "Run host-runner test file PATH on this Consent runtime, form by form."
      "ROOT is the absolute working directory the run is scoped to (file access"
      "and include resolution). Each form is evaluated through a durable"
      "interaction context under the host-run capability bundle; EMIT is called"
      "with the program output each form produced so the host can stream it to"
      "real stdout. Returns #t when every form completes, or the failing"
      "`evaluation-result' datum at the first error -- so a CLI caller exits"
      "non-zero exactly when a captured test assertion raised."
      #((parameters
         (path
          (type any)
          (description
           ("Filesystem path of the host-runner test file to evaluate"
            "form by form.")))
         (root
          (type any)
          (description
           ("Absolute working directory the run is scoped to for file"
            "access and include resolution.")))
         (emit
          (type any)
          (description
           ("Procedure called with each form's captured program output"
            "so the host can stream it to real stdout."))))
        (returns
         (type any)
         (description
          ("#t when every form completes, or the failing"
           "`evaluation-result' datum at the first error.")))
        (effects state-read host-eval state-write error))
      (let ((source (cli-script-source-from-file path))
            (interaction
             (consent-make-interaction-context
              (cli-script-host-run-options root))))
        (let loop ((rest (consent-read-all source)))
          (if (null? rest)
              #t
              (let ((result
                     (consent-interaction-eval-form interaction (car rest))))
                (emit (consent-interaction-program-output interaction))
                (if (eq? (script--result-field result 'status) 'error)
                    result
                    (loop (cdr rest))))))))))

;;; script.sld ends here
