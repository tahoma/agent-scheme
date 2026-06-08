;;; consent-repl-chrome.el --- Shared REPL chrome model realized as Emacs faces  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Emacs host realization of the host-neutral REPL presentation ("chrome")
;; model.  This module is the Emacs parity twin of the portable
;; `(cli repl-chrome)' library (scheme/cli/repl-chrome.sld): it ships the same
;; named chromes and the same record-to-role mapping over the cross-host REPL
;; interaction contract record vocabulary (docs/repl-interaction-contract.md),
;; and realizes the shared **semantic roles** as Emacs faces instead of ANSI SGR.
;;
;; Chrome is host-specific *presentation* under the #390 contract: the raw
;; record stream emitted by `consent-repl-stream' is the canonical,
;; machine-readable parity surface, and chrome rides above it.  Parity here is
;; familiarity, not byte-identity -- the terminal paints ANSI, Emacs paints
;; faces -- so the two surfaces share the chrome *names* and the per-record
;; *roles* while each host realizes those roles on its own substrate.
;;
;; A chrome is a pure function `(render RECORD) -> nil | STRING | SEGMENTS'.
;; `nil' suppresses the record; a string is emitted verbatim and never faced (so
;; the `datum' chrome reproduces the raw record stream regardless of styling); a
;; list of `(ROLE . TEXT)' segments expresses styling as named semantic roles
;; (`furniture', `prompt-session', `prompt-ordinal', `result-marker',
;; `result-value', `error-marker', `error-text', `exit-status', and the neutral
;; `submission' role for echoed source).  `consent-repl-chrome-paint' realizes a
;; chrome result as a propertized string, mapping each colored role to a face.
;;
;; The built-in chromes are ordinary registered procedures over records, not
;; special-cased branches, so a future custom chrome (#426) is the same kind of
;; value.  The `datum' chrome reproduces the raw record stream one datum per line
;; and is always reachable, so the canonical surface is never suppressed by the
;; active chrome.

;;; Code:

(require 'seq)
(require 'consent-reader)
(require 'consent-result)

;;;; Faces (the Emacs substrate: roles realized as faces, never ANSI)

(defgroup consent-repl-chrome nil
  "Faces realizing the shared REPL chrome semantic roles in Emacs."
  :group 'consent)

(defface consent-repl-chrome-furniture
  '((t :inherit shadow))
  "Face for neutral chrome furniture (punctuation and whitespace)."
  :group 'consent-repl-chrome)

(defface consent-repl-chrome-prompt-session
  '((t :inherit font-lock-keyword-face))
  "Face for the session label in a REPL prompt."
  :group 'consent-repl-chrome)

(defface consent-repl-chrome-prompt-ordinal
  '((t :inherit font-lock-constant-face))
  "Face for the ordinal in a REPL prompt."
  :group 'consent-repl-chrome)

(defface consent-repl-chrome-result-marker
  '((t :inherit success))
  "Face for the result marker (`=> ')."
  :group 'consent-repl-chrome)

(defface consent-repl-chrome-error-marker
  '((t :inherit error))
  "Face for the condition marker (`!! ')."
  :group 'consent-repl-chrome)

(defface consent-repl-chrome-error-text
  '((t :inherit error))
  "Face for condition (error/diagnostic) text."
  :group 'consent-repl-chrome)

(defface consent-repl-chrome-exit-status
  '((t :inherit warning))
  "Face for the close status in an exit record."
  :group 'consent-repl-chrome)

(defun consent-repl-chrome--role-face (role)
  "Return the face realizing ROLE, or nil for an unfaced role.
The neutral `result-value' and `submission' roles -- and any unknown role --
return nil, mirroring the portable terminal renderer leaving them uncolored."
  (pcase role
    ('furniture 'consent-repl-chrome-furniture)
    ('prompt-session 'consent-repl-chrome-prompt-session)
    ('prompt-ordinal 'consent-repl-chrome-prompt-ordinal)
    ('result-marker 'consent-repl-chrome-result-marker)
    ('error-marker 'consent-repl-chrome-error-marker)
    ('error-text 'consent-repl-chrome-error-text)
    ('exit-status 'consent-repl-chrome-exit-status)
    (_ nil)))

;;;; Record field access (the records are the shared cross-host vocabulary)

(defun consent-repl-chrome--kind (record)
  "Return RECORD's leading tag name string, or nil when RECORD is not a record."
  (and (consp record)
       (consent-symbol-p (car record))
       (consent-symbol-name (car record))))

(defun consent-repl-chrome--field (record name)
  "Return the single value of field NAME (a string) in record RECORD, or nil."
  (let ((entry (seq-find
                (lambda (candidate)
                  (and (consp candidate)
                       (consent-symbol-p (car candidate))
                       (equal (consent-symbol-name (car candidate)) name)))
                (cdr-safe record))))
    (and entry (cadr entry))))

(defun consent-repl-chrome--field-symbol-name (record name)
  "Return the symbol name of the symbol-valued field NAME in RECORD, or nil."
  (let ((value (consent-repl-chrome--field record name)))
    (and (consent-symbol-p value) (consent-symbol-name value))))

(defun consent-repl-chrome--field-true-p (record name)
  "Return non-nil when boolean field NAME in RECORD is the Scheme true datum."
  (eq (consent-repl-chrome--field record name) consent-true))

(defun consent-repl-chrome--display (record)
  "Return RECORD's human-readable `display' string, or the empty string."
  (or (consent-repl-chrome--field record "display") ""))

(defun consent-repl-chrome--ordinal-string (record)
  "Return RECORD's `ordinal' field rendered as a decimal string."
  (let ((value (consent-repl-chrome--field record "ordinal")))
    (if value (consent-value->external value) "")))

;; The lone default session id, emitted when no session was named.  The
;; `comment' chrome shows the ordinal alone for it and grows a session label
;; only for a named (non-default) session.
(defconst consent-repl-chrome--default-session "repl-main"
  "Name of the lone default REPL session.")

(defun consent-repl-chrome--anonymous-session-p (session)
  "Return non-nil when SESSION (a name string) is the lone default session."
  (equal session consent-repl-chrome--default-session))

;;;; Segment helpers

(defun consent-repl-chrome--seg (role text)
  "Build a `(ROLE . TEXT)' styling segment."
  (cons role text))

(defun consent-repl-chrome--furniture (text)
  "Build a neutral furniture segment carrying punctuation/whitespace TEXT."
  (consent-repl-chrome--seg 'furniture text))

;;;; Input-echo signal: does the host already echo interaction input?

;; The portable terminal twin (`cli-repl-chrome-input-echoed?' in
;; scheme/cli/repl-chrome.sld) carries this signal so the `comment' chrome keeps
;; exactly one replayable copy of each submission: an interactive TTY echoes the
;; typed form in cooked mode, so the chrome must suppress its own echo there and
;; keep echoing when input is piped or redirected.  This dynamic variable is the
;; Emacs twin of that parameter.  Both Emacs entries leave it nil: the batch
;; entry (`consent-repl-stream-main') reads piped stdin with no terminal echo,
;; and the interactive command renders submitted source into a buffer rather
;; than echoing a live terminal -- so neither host path double-echoes.  The
;; variable exists for model symmetry and lets a future echoing Emacs front end
;; bind it without re-deriving the gate.
(defvar consent-repl-chrome-input-echoed nil
  "Non-nil when the host already echoes REPL interaction input.
When non-nil, the `comment' chrome suppresses its own submission echo so a
captured transcript holds exactly one replayable copy of each form.")

;;;; The `comment' chrome (default): block-comment furniture, replayable

(defun consent-repl-chrome--comment (record)
  "Render RECORD under the default `comment' chrome.
Every prompt, result, and diagnostic is a block comment and a complete
submission is echoed as bare source, so the whole control-channel stream is
valid Consent Scheme that replays to the same evaluation apart from program
output.  The submission echo is suppressed when
`consent-repl-chrome-input-echoed' is non-nil (the host already echoes the typed
form), so a captured transcript holds exactly one replayable copy of each form
in both the piped and the interactive case."
  (let ((kind (consent-repl-chrome--kind record)))
    (cond
     ((equal kind "repl-prompt")
      (if (equal (consent-repl-chrome--field-symbol-name record "state")
                 "continuation")
          (list (consent-repl-chrome--furniture "#| ... |# "))
        (let ((session (consent-repl-chrome--field-symbol-name record "session"))
              (ordinal (consent-repl-chrome--ordinal-string record)))
          (append
           (list (consent-repl-chrome--furniture "#| "))
           (if (consent-repl-chrome--anonymous-session-p session)
               nil
             (list (consent-repl-chrome--seg 'prompt-session session)
                   (consent-repl-chrome--furniture ":")))
           (list (consent-repl-chrome--seg 'prompt-ordinal ordinal)
                 (consent-repl-chrome--furniture " |# "))))))
     ((equal kind "repl-submission")
      ;; Echo a whole form as bare code so it replays; leave an incomplete
      ;; (EOF-truncated) submission unechoed so the stream stays balanced.  When
      ;; the host already echoes interaction input (an interactive TTY in cooked
      ;; mode), suppress this echo too: the terminal's own echo is the single
      ;; replayable copy, and a second copy would replay the form twice.
      (if (and (consent-repl-chrome--field-true-p record "complete")
               (not consent-repl-chrome-input-echoed))
          (list (consent-repl-chrome--seg
                 'submission (consent-repl-chrome--field record "source"))
                (consent-repl-chrome--furniture "\n"))
        nil))
     ((equal kind "repl-result")
      (list (consent-repl-chrome--furniture "#| ")
            (consent-repl-chrome--seg 'result-marker "=> ")
            (consent-repl-chrome--seg 'result-value
                                      (consent-repl-chrome--display record))
            (consent-repl-chrome--furniture " |#\n")))
     ((equal kind "repl-condition")
      (list (consent-repl-chrome--furniture "#| ")
            (consent-repl-chrome--seg 'error-marker "!! ")
            (consent-repl-chrome--seg 'error-text
                                      (consent-repl-chrome--display record))
            (consent-repl-chrome--furniture " |#\n")))
     ((equal kind "repl-exit")
      (list (consent-repl-chrome--furniture "#| exit ")
            (consent-repl-chrome--seg
             'exit-status
             (or (consent-repl-chrome--field-symbol-name record "status")
                 "closed-ok"))
            (consent-repl-chrome--furniture " |#\n")))
     (t nil))))

;;;; The `datum' chrome: the canonical record stream, one datum per line

(defun consent-repl-chrome--datum (record)
  "Render RECORD as the canonical raw datum stream, one datum per line.
Returns a plain string, so the painter never faces it: the datum chrome is the
raw record stream regardless of styling."
  (concat (consent-result->external record) "\n"))

;;;; The `classic' chrome: `>'/`|' prompts and bare values

(defun consent-repl-chrome--classic (record)
  "Render RECORD under the `classic' chrome: a `>'/`|' prompt and bare values,
with submissions and the exit record suppressed."
  (let ((kind (consent-repl-chrome--kind record)))
    (cond
     ((equal kind "repl-prompt")
      ;; `> ' and `| ' are both two columns wide, so a continued form's code
      ;; aligns under the first submission's code; `| ' reads as a continuation
      ;; gutter rule.
      (if (equal (consent-repl-chrome--field-symbol-name record "state")
                 "continuation")
          (list (consent-repl-chrome--furniture "| "))
        (list (consent-repl-chrome--furniture "> "))))
     ((equal kind "repl-result")
      (list (consent-repl-chrome--seg 'result-value
                                      (consent-repl-chrome--display record))
            (consent-repl-chrome--furniture "\n")))
     ((equal kind "repl-condition")
      (list (consent-repl-chrome--seg 'error-text
                                      (consent-repl-chrome--display record))
            (consent-repl-chrome--furniture "\n")))
     (t nil))))

;;;; The `quiet' chrome: no prompts; results and conditions only

(defun consent-repl-chrome--quiet (record)
  "Render RECORD under the `quiet' chrome: results and conditions only, with
prompts, submissions, and the exit record suppressed."
  (let ((kind (consent-repl-chrome--kind record)))
    (cond
     ((equal kind "repl-result")
      (list (consent-repl-chrome--seg 'result-value
                                      (consent-repl-chrome--display record))
            (consent-repl-chrome--furniture "\n")))
     ((equal kind "repl-condition")
      (list (consent-repl-chrome--seg 'error-text
                                      (consent-repl-chrome--display record))
            (consent-repl-chrome--furniture "\n")))
     (t nil))))

;;;; The `silent' chrome: suppress every interaction record

(defun consent-repl-chrome--silent (record)
  "Render RECORD under the `silent' chrome: emit nothing for any record, so only
program output reaches the user."
  (and record nil))

;;;; Chrome registry

;; Built-in chromes are ordinary registered procedures over records.  A future
;; custom chrome (#426) is the same kind of value, so it slots in here without
;; changing the painter or the rendering loop.
(defconst consent-repl-chrome--registry
  (list (cons 'comment #'consent-repl-chrome--comment)
        (cons 'datum #'consent-repl-chrome--datum)
        (cons 'classic #'consent-repl-chrome--classic)
        (cons 'quiet #'consent-repl-chrome--quiet)
        (cons 'silent #'consent-repl-chrome--silent))
  "Alist mapping chrome name symbols to their render procedures.")

(defun consent-repl-chrome-lookup (name)
  "Return the chrome procedure registered under NAME (a symbol or string), or nil."
  (let* ((symbol (if (stringp name) (intern name) name))
         (entry (assq symbol consent-repl-chrome--registry)))
    (and entry (cdr entry))))

(defun consent-repl-chrome-names ()
  "Return the list of registered chrome name symbols, in declaration order."
  (mapcar #'car consent-repl-chrome--registry))

(defun consent-repl-chrome-default-name ()
  "Return the default chrome name, consistent with the portable terminal default."
  'comment)

;;;; Painter: realize a chrome result as a propertized string

(defun consent-repl-chrome--segment->string (segment apply-faces)
  "Render one `(ROLE . TEXT)' SEGMENT.
Apply ROLE's face when APPLY-FACES is non-nil; otherwise return plain text."
  (let ((role (car segment))
        (text (cdr segment)))
    (if apply-faces
        (let ((face (consent-repl-chrome--role-face role)))
          (if face (propertize text 'face face) text))
      text)))

(defun consent-repl-chrome-paint (result &optional apply-faces)
  "Realize a chrome RESULT as a string, or nil when RESULT suppresses the record.
RESULT is nil, a plain string, or a list of `(ROLE . TEXT)' segments.  A plain
string is returned verbatim and never faced; segment faces are applied when
APPLY-FACES is non-nil, so callers can recover the plain text by omitting it."
  (cond
   ((null result) nil)
   ((stringp result) result)
   (t (mapconcat (lambda (segment)
                   (consent-repl-chrome--segment->string segment apply-faces))
                 result ""))))

(provide 'consent-repl-chrome)

;;; consent-repl-chrome.el ends here
