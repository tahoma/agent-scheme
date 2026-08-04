;;; consent-script.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Emacs-host parity twin of the portable `(cli script)' library.  It lets a
;; Consent Scheme source file marked with a `#!' line be run directly as an
;; executable script (docs/executable-scripts.md): the non-interactive
;; counterpart to the interactive REPL.
;;
;; `#!' is not free in Scheme -- it prefixes reader directives (`#!fold-case'),
;; version flags (`#!r6rs'), named values (`#!eof'), and DSSSL keywords
;; (`#!optional').  So a shebang is recognized only NARROWLY -- a `#!' that is
;; the first two bytes of the source followed by `/' or whitespace -- and is
;; consumed here, at the script-loading boundary, before the source reaches the
;; reader.  `consent--skip-directive' is left untouched, so `#!fold-case' and
;; every other `#!'-token keep their reader-token meaning everywhere else.
;;
;; `consent-script-run-file' is the Emacs batch equivalent of the runtime's
;; `--script FILE'. It evaluates the script through `consent-eval-source', so a
;; script inherits the noninteractive fail-closed policy posture: confirm-gated
;; actions are denied unless covered by an explicit grant, a policy file, or a
;; preloaded approval, and no raw host objects are exposed to script values.

;;; Code:

(require 'cl-lib)
(require 'consent-eval)

(defun consent--script-shebang-introducer-p (char)
  "Return non-nil when CHAR may follow `#!' to introduce a shebang line.
Only `/' (an absolute interpreter path) and intertoken whitespace qualify;
`#!fold-case', `#!r6rs', and the other `#!'-tokens begin with letters and are
deliberately excluded so they keep their reader-token meaning."
  (memq char '(?/ ?\s ?\t)))

(defun consent-script-shebang-line-p (source)
  "Return non-nil when SOURCE begins with an executable-script shebang line.
The rule is narrow: the first two characters are `#!' and the third is `/' or
intertoken whitespace.  A bare `#!' at end of input, or `#!' followed by a name
character such as in `#!fold-case', is not a shebang."
  (and (>= (length source) 3)
       (eq (aref source 0) ?#)
       (eq (aref source 1) ?!)
       (consent--script-shebang-introducer-p (aref source 2))
       t))

(defun consent-script-strip-shebang (source)
  "Return SOURCE with a leading executable-script shebang line removed.
When SOURCE begins with a shebang (see `consent-script-shebang-line-p'), the
shebang text is consumed up to but not including its terminating newline, so\
 the
remaining source keeps that newline as a blank first line and every later datum
keeps its original line number.  A shebang with no trailing newline yields the
empty string.  SOURCE without a shebang is returned unchanged, leaving
`#!fold-case' and every other `#!'-token for the reader."
  (if (consent-script-shebang-line-p source)
      (let ((newline (cl-position ?\n source)))
        (if newline
            (substring source newline)
          ""))
    source))

(defun consent-script-source-from-file (path)
  "Return the contents of script PATH with any leading shebang line removed."
  (consent-script-strip-shebang
   (with-temp-buffer
     (insert-file-contents path)
     (buffer-string))))

(defun consent-script--options-with-command-line (path options arguments)
  "Return OPTIONS with PATH and ARGUMENTS exposed as script command-line."
  (append (list :command-line (cons path (copy-sequence (or arguments nil))))
          options))

(defun consent-script-run-file (path &optional environment options arguments)
  "Run executable Consent Scheme script PATH and return its last value.
A leading shebang line is consumed before reading, so a file made executable
with `#!/usr/bin/env consent' (or the `/bin/sh' polyglot) reads correctly.
Evaluation goes through `consent-eval-source' with ENVIRONMENT and OPTIONS in
the consent runtime.  Ambient host capabilities -- opening a named file, a
process, network -- fail closed without a grant, policy file, or preloaded
approval.  The standard `(command-line)' value is PATH followed by ARGUMENTS,
matching the
compiled `--script' and bare-file entrypoints without exposing the host process
command line.
standard streams are consented by invocation: when OPTIONS supply the host
stream devices (`:program-input-reader', `:program-output-writer',
`:program-error-writer') with one matching `port' grant per stream, the
script reads stdin and writes stdout/stderr
\(docs/repl-interaction-contract.md, \"Program Stream Model\"); input is pulled
from the reader on demand so a `(read-line)'
filter streams incrementally.  Finite in-memory input uses a reader built with
`consent-program-input-from-string'."
  (consent-eval-source
   (consent-script-source-from-file path)
   environment
   (consent-script--options-with-command-line path options arguments)))

(provide 'consent-script)

;;; consent-script.el ends here
