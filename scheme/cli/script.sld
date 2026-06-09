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
          cli-script-run-file)
  (import (scheme base)
          (scheme file)
          (consent reader)
          (consent eval))

  (begin

    (define (script--whitespace-after-bang? char)
      "Return #t when CHAR (`/' or intertoken whitespace) may follow `#!' to introduce a shebang; `#!fold-case' and other letter-led `#!'-tokens are excluded."
      (or (char=? char #\/)
          (char=? char #\space)
          (char=? char #\tab)))

    (define (cli-script-shebang-line? source)
      "Return #t when SOURCE begins with an executable-script shebang: `#!' as the first two characters followed by `/' or whitespace, narrow enough to leave `#!fold-case' and other `#!'-tokens alone."
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
      "Return SOURCE with a leading shebang line removed up to (not including) its newline, so the remaining source keeps a blank first line and later datums keep their line numbers; SOURCE without a shebang is returned unchanged for the reader."
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
      "Return PATH's contents with any leading executable-script shebang removed, ready for the reader."
      (cli-script-strip-shebang (script--read-file-string path)))

    (define (script--result-status result)
      "Return the status symbol of an evaluation-result datum, or #f."
      (let ((entry (and (pair? result) (assq 'status (cdr result)))))
        (and entry (cadr entry))))

    (define (cli-script-run-file path . rest)
      "Run executable Consent Scheme script PATH through the Consent interpreter and return its last evaluation result.
A leading shebang line is consumed before reading. Evaluation runs through a
durable interaction context (REST may supply session-id/policy-actions/grants),
which carries the non-interactive script posture: program output is captured and
re-emitted on the host's standard output, while confirm-gated host capabilities
(filesystem mutation, network, process control, ...) are denied without an
explicit grant. A form whose result carries an error status raises, so a CLI
caller's guard can exit non-zero. This is the host-neutral peer of the Emacs
`consent-script-run-file' and shares the REPL's interaction-context posture."
      (let* ((options (if (pair? rest) (car rest) '()))
             (interaction (consent-make-interaction-context options))
             (forms (consent-read-all (cli-script-source-from-file path)))
             (out-port (current-output-port)))
        (let loop ((remaining forms) (last-result #f))
          (if (null? remaining)
              last-result
              (let ((result
                     (consent-interaction-eval-form interaction (car remaining))))
                (let ((output (consent-interaction-program-output interaction)))
                  (when (> (string-length output) 0)
                    (write-string output out-port)))
                (if (eq? (script--result-status result) 'error)
                    (error "consent script evaluation failed" result)
                    (loop (cdr remaining) last-result))))))))) ; last value unused by CLI

;;; script.sld ends here
