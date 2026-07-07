;;; consent-eval.el --- Public R7RS evaluator entry points  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Public orchestration functions for Consent Scheme evaluation.  The interpreter
;; backend lives in `consent-interpreter'.

;;; Code:

(require 'cl-lib)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-audit)
(require 'consent-policy)
(require 'consent-base)
(require 'consent-approval)
(require 'consent-memory)
(require 'consent-library)
(require 'consent-macro)
(require 'consent-interpreter)
(require 'consent-session)

(defun consent--eval-context-library-keys (context)
  "Return sorted library keys imported or registered in CONTEXT."
  (let (keys)
    (maphash
     (lambda (key _library)
       (push key keys))
     (consent--eval-context-libraries context))
    (sort keys #'string<)))

(defun consent--audit-evaluation-success
    (input-form value context)
  "Record a successful evaluation of INPUT-FORM producing VALUE."
  (consent-audit-record
   'evaluation
   `((category . pure-r7rs)
     (operation . "evaluate")
     (input-form . ,input-form)
     (imported-libraries . ,(consent--eval-context-library-keys context))
     (decision . allowed)
     (result . ,(consent-value->external value)))))

(defun consent--audit-evaluation-error
    (input-form condition context)
  "Record a failed evaluation of INPUT-FORM with CONDITION."
  (consent-audit-record
   'evaluation
   `((category . pure-r7rs)
     (operation . "evaluate")
     (input-form . ,input-form)
     (imported-libraries . ,(consent--eval-context-library-keys context))
     (decision . error)
     (error . ,(error-message-string condition)))))

(defun consent--resignal (condition)
  "Signal CONDITION again after audit handling."
  (signal (car condition) (cdr condition)))

;;;###autoload
(defun consent-eval (expression &optional environment options)
  "Evaluate one Consent Scheme EXPRESSION datum.
ENVIRONMENT defaults to a fresh base environment.  OPTIONS is a
plist supporting `:max-steps', `:max-non-tail-steps',
`:max-value-nodes', `:max-source-metadata', `:max-interned-symbols',
`:max-host-callbacks', `:max-events', and `:max-event-nodes'."
  (let ((max-lisp-eval-depth (max max-lisp-eval-depth 16384))
        (context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment)))
        (input-form (consent-value->external expression)))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (consent--connect-standard-streams! context options)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (consent--ensure-base-syntax context eval-environment)
          (let ((value
                 (consent--trampoline
                  expression eval-environment context)))
            (consent-capability-expire-after-eval! context)
            (consent--audit-evaluation-success
             input-form value context)
            value))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--resignal condition)))))

;;;###autoload
(defun consent-eval-source (source &optional environment options)
  "Read and evaluate all datums in SOURCE.
ENVIRONMENT defaults to a fresh base environment.  The returned value
is the result of the last command or definition."
  (let* ((max-lisp-eval-depth (max max-lisp-eval-depth 16384))
         (context (consent--new-eval-context options))
         (eval-environment (or environment
                               (consent-make-base-environment)))
         (input-form source))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (consent--connect-standard-streams! context options)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (let* ((forms (consent-read-all source options))
                 (sequence (consent--make-sequence forms t)))
            (consent--ensure-base-syntax context eval-environment)
            (let ((value
                   (consent--trampoline
                    sequence eval-environment context)))
              (consent-capability-expire-after-eval! context)
              (consent--audit-evaluation-success
               input-form value context)
              value)))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--resignal condition)))))

;;;###autoload
(defalias 'consent-eval-string #'consent-eval-source
  "Read and evaluate all datums in a source string.
This alias is kept for callers that describe string input
explicitly; it has the same calling convention as
`consent-eval-source'.")

;;;###autoload
(defun consent-program-input-from-string (content)
  "Return a one-shot program-input reader that yields CONTENT once, then ends.
This is the honest finite-input constructor -- a stream whose whole contents
are available immediately and which then reaches end of stream.  Use it for
fixtures, captured-transcript replay, and other genuinely in-memory input; it
is never a way to model a live stdin, which has a time dimension a buffer
cannot represent.
Mirrors the portable `(consent eval)' `consent-program-input-from-string'."
  (let ((pending content))
    (lambda ()
      (prog1 pending (setq pending nil)))))

;;;###autoload
(defun consent-program-input-from-bytevector (content)
  "Return a one-shot binary program-input reader yielding CONTENT once, then ends.
CONTENT is a vector of bytes -- Emacs's host byte-vector container, the
representation a binary input port buffers -- whose whole finite contents are
available immediately and then at end of stream.  Binary peer of
`consent-program-input-from-string'; use it for fixtures and captured byte
streams, never to model a live byte pipe.  Mirrors the portable `(consent eval)'
`consent-program-input-from-bytevector'."
  (let ((pending content))
    (lambda ()
      (prog1 pending (setq pending nil)))))

;;;###autoload
(defun consent-session-eval-source (id source &optional options)
  "Evaluate SOURCE inside persistent session ID.
OPTIONS may override the session context budgets for this evaluation.  The
session preserves definitions, imports, macros, transcript entries, recent
agent events, and handle references across calls."
  (let* ((session (consent-session--require id))
         (context (consent-session-context session))
         (environment (consent-session-environment session))
         (input-form source)
         (base-syntax-installed
          (consent--eval-context-base-syntax-installed context)))
    (when options
      (when (plist-member options :max-steps)
        (setf (consent--eval-context-maximum-steps context)
              (plist-get options :max-steps)))
      (when (plist-member options :max-non-tail-steps)
        (setf (consent--eval-context-maximum-steps context)
              (plist-get options :max-non-tail-steps)))
      (when (plist-member options :max-value-nodes)
        (setf (consent--eval-context-maximum-value-nodes context)
              (plist-get options :max-value-nodes)))
      (when (plist-member options :max-source-metadata)
        (setf (consent--eval-context-maximum-source-metadata context)
              (plist-get options :max-source-metadata)))
      (when (plist-member options :max-interned-symbols)
        (setf (consent--eval-context-maximum-interned-symbols context)
              (plist-get options :max-interned-symbols)))
      (when (plist-member options :max-host-callbacks)
        (setf (consent--eval-context-maximum-host-callbacks context)
              (plist-get options :max-host-callbacks)))
      (consent--apply-current-context-options! context options))
    (consent-session--prepare-eval! session)
    (let ((start-count (consent-session--audit-start-count)))
      (consent-session--record-eval-start! session source)
      (condition-case condition
          (progn
            (consent-policy-authorize
             'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
            (let ((consent--memory-current-session session)
                  (consent--approval-current-session
                   (consent-session-id session)))
              (let* ((forms (consent-read-all source options))
                     (sequence (consent--make-sequence forms t)))
                (consent--ensure-base-syntax context environment)
                (unless base-syntax-installed
                  (setf (consent-session-baseline-syntax session)
                        (consent-session--syntax-current-names
                         (consent--eval-context-syntax-environment
                          context))))
                (let ((value
                       (consent--trampoline
                        sequence environment context)))
                  (consent-capability-expire-after-eval! context)
                  (consent-session--sync-capability-grants! session)
                  (consent--audit-evaluation-success
                   input-form value context)
                  (consent-session--record-eval-success!
                   session source value start-count)))))
        (error
         (consent-capability-expire-after-eval! context)
         (consent-session--sync-capability-grants! session)
         (consent--audit-evaluation-error input-form condition context)
         (consent-session--record-eval-error!
          session source condition start-count)
         (consent--resignal condition))))))

;;;###autoload
(defalias 'consent-session-eval-string #'consent-session-eval-source
  "Read and evaluate SOURCE inside a persistent Consent Scheme session.")

;;;###autoload
(defun consent-eval-result (expression &optional environment options)
  "Evaluate EXPRESSION and return a Scheme-readable result datum."
  (let ((max-lisp-eval-depth (max max-lisp-eval-depth 16384))
        (context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment)))
        (input-form (consent-value->external expression)))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (consent--connect-standard-streams! context options)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (consent--ensure-base-syntax context eval-environment)
          (let ((value
                 (consent--trampoline
                  expression eval-environment context)))
            (consent-capability-expire-after-eval! context)
            (consent--audit-evaluation-success
             input-form value context)
            (consent--ok-result-datum value context)))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--condition-result-datum condition context)))))

;;;###autoload
(defun consent-eval-source-result (source &optional environment options)
  "Read and evaluate SOURCE and return a Scheme-readable result datum."
  (let ((max-lisp-eval-depth (max max-lisp-eval-depth 16384))
        (context (consent--new-eval-context options))
        (eval-environment (or environment
                              (consent-make-base-environment)))
        (input-form source))
    (setf (consent--eval-context-interaction-environment context)
          eval-environment)
    (consent--connect-standard-streams! context options)
    (condition-case condition
        (progn
          (consent-policy-authorize
           'pure-r7rs "evaluate" `((input-form . ,input-form)) context)
          (let* ((forms (consent-read-all source options))
                 (sequence (consent--make-sequence forms t)))
            (consent--ensure-base-syntax context eval-environment)
            (let ((value
                   (consent--trampoline
                    sequence eval-environment context)))
              (consent-capability-expire-after-eval! context)
              (consent--audit-evaluation-success
               input-form value context)
              (consent--ok-result-datum value context))))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--audit-evaluation-error input-form condition context)
       (consent--condition-result-datum condition context)))))

;;;; Durable interaction context for incremental REPL sessions

;; A durable interaction context bundles the persistent state a REPL session
;; reuses across submissions: the evaluator options (carrying `:session-id',
;; policy actions, and capability grants), the mutable value environment, the
;; syntax environment, and the program-output port.  Each submission still runs
;; in a fresh evaluation context with its own step/host-callback/event budget --
;; exactly as `consent-eval-source-result' does -- but that context reuses the
;; persisted value and syntax environments.  Value definitions and imports
;; persist because they mutate the shared value environment; macros and imported
;; syntax persist because the shared syntax environment is threaded through
;; instead of being rebuilt per call.  This is the Emacs peer of the portable
;; `(consent eval)' interaction context that drives the portable terminal REPL
;; shell, so the two hosts read and evaluate one form at a time over the same
;; durable substrate (docs/repl-interaction-contract.md).

(cl-defstruct (consent--interaction-context
               (:constructor consent--make-interaction-context-record
                             (options environment syntax-environment
                              program-output-port program-input-port))
               (:copier nil))
  "Durable state a REPL session reuses across submissions.
OPTIONS are the evaluator options (carrying `:session-id', `:policy-actions',
and `:capability-grants').  ENVIRONMENT is the persistent value environment and
SYNTAX-ENVIRONMENT the persistent syntax environment, so definitions, imports,
and macros persist across `consent-interaction-eval-form' submissions.
PROGRAM-OUTPUT-PORT captures what each submission writes to current output,
separated from the interaction record stream.  PROGRAM-INPUT-PORT, when present,
is the shared stdin cursor the REPL form reader and evaluated reads both draw
from (or nil when program input is not connected)."
  options environment syntax-environment program-output-port program-input-port)

;;;###autoload
(defun consent-make-interaction-context (&optional options)
  "Create a durable interaction context from plist OPTIONS.
OPTIONS may carry `:session-id', `:policy-actions', and `:capability-grants'
whose definitions, imports, macros, and program output persist across
`consent-interaction-eval-form' submissions.  When OPTIONS supply a
`:program-input-reader' and a matching active `port'/`read' grant backed by
`stdin', a program-input port is created and shared as the session's single
stdin cursor.  Mirrors the portable `(consent eval)'
`consent-make-interaction-context'."
  (let* ((context (consent--new-eval-context options))
         (environment (consent-make-base-environment))
         (reader (consent--program-input-reader-from-options options))
         (grant (and reader
                     (consent--find-standard-stream-grant context 'stdin 'read)))
         (input-port (and reader grant
                          (consent--make-program-input-port grant reader))))
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (consent--ensure-base-syntax context environment)
    (consent--make-interaction-context-record
     options environment
     (consent--eval-context-syntax-environment context)
     (consent--primitive-open-output-string nil nil)
     input-port)))

;;;###autoload
(defun consent-session-interaction-context (session-id &optional options)
  "Build a durable interaction context that evaluates over session SESSION-ID.
Unlike `consent-make-interaction-context', which owns a private base
environment, the returned context shares session SESSION-ID's live value and
syntax environments, so definitions, imports, and macros introduced through
`consent-interaction-eval-form' are visible to -- and see those introduced by --
`consent-session-eval-source' and the other session-bound Emacs eval paths.  The
session's capability grants are merged into the evaluation options so a REPL
surface inherits the authority the session already holds.  OPTIONS may carry
`:program-input-reader' (and the matching active `port'/`read'/`stdin' grant in
its `:capability-grants') to connect the shared stdin cursor, plus the other
evaluator options `consent-make-interaction-context' accepts.  This is the
substrate the in-editor comint REPL surface drives so it inhabits the same live
session the rest of Emacs evaluates against, rather than an island."
  (let* ((session (consent-session--require session-id))
         (environment (consent-session-environment session))
         (context (consent-session-context session)))
    ;; Install base derived syntax into the session's shared syntax environment
    ;; the same way `consent-session-eval-source' does lazily on first eval, so
    ;; the first REPL submission can already use derived syntax.  Mirroring its
    ;; baseline-syntax capture keeps `consent-session--session-macros' honest
    ;; whether the bridge or an ordinary session eval touches the session first.
    (let ((base-syntax-installed
           (consent--eval-context-base-syntax-installed context)))
      (consent--ensure-base-syntax context environment)
      (unless base-syntax-installed
        (setf (consent-session-baseline-syntax session)
              (consent-session--syntax-current-names
               (consent--eval-context-syntax-environment context)))))
    (let* ((syntax-environment (consent--eval-context-syntax-environment context))
           (caller-grants (plist-get options :capability-grants))
           ;; Prepended keys win under `plist-get', so the merged session id and
           ;; capability grants shadow any the caller left in OPTIONS without
           ;; mutating the caller's plist.
           (merged-options
            (append (list :session-id session-id
                          :capability-grants
                          (append caller-grants
                                  (consent-session-capability-grants session)))
                    options))
           (eval-context (consent--new-eval-context merged-options))
           (reader (consent--program-input-reader-from-options merged-options))
           (grant (and reader
                       (consent--find-standard-stream-grant
                        eval-context 'stdin 'read)))
           ;; A pre-built `:program-input-port' lets the multi-session REPL share
           ;; one stdin cursor across every session it switches between, instead
           ;; of forking a fresh cursor per session.
           (input-port (or (plist-get merged-options :program-input-port)
                           (and reader grant
                                (consent--make-program-input-port grant reader)))))
      (consent--make-interaction-context-record
       merged-options environment syntax-environment
       (consent--primitive-open-output-string nil nil)
       input-port))))

;;;###autoload
(defun consent-interaction-program-input-port (interaction)
  "Return INTERACTION's shared program-input port, or nil when disconnected."
  (consent--interaction-context-program-input-port interaction))

;;;###autoload
(defun consent-interaction-seed-program-input! (interaction text)
  "Seed the shared program-input cursor with TEXT (the post-form remainder).
An evaluated read then consumes the input that follows the just-read submission.
A no-op when program input is not connected.  Mirrors the portable twin."
  (let ((port (consent--interaction-context-program-input-port interaction)))
    (when port
      (setf (consent--port-source port) text)
      (setf (consent--port-position port) 0))))

;;;###autoload
(defun consent-interaction-program-input-remainder (interaction)
  "Return the shared program-input cursor's unconsumed remainder, or nil.
The REPL engine threads this back as the next form-reading buffer so neither
reader steals the other's characters.  Mirrors the portable twin."
  (let ((port (consent--interaction-context-program-input-port interaction)))
    (when port
      (substring (consent--port-source port)
                 (consent--port-position port)))))

;;;###autoload
(defalias 'consent-interaction-context-p #'consent--interaction-context-p
  "Return non-nil when its argument is a durable interaction context.")

;;;###autoload
(defun consent-interaction-context-session-id (interaction)
  "Return the session id INTERACTION evaluates under, or nil when unsessioned."
  (plist-get (consent--interaction-context-options interaction) :session-id))

;;;###autoload
(defun consent-interaction-program-output (interaction)
  "Return program output the most recent `consent-interaction-eval-form' wrote.
The buffer is cleared before each evaluation."
  (or (consent--port-contents
       (consent--interaction-context-program-output-port interaction))
      ""))

;;;###autoload
(defun consent-interaction-eval-form (interaction form)
  "Evaluate one already-read top-level FORM in durable INTERACTION.
Reuse INTERACTION's value and syntax environments and program-output port and
return an `evaluation-result' datum (ok/values or captured error) like
`consent-eval-source-result', never signaling on an evaluator error.  Mirrors
the portable `(consent eval)' `consent-interaction-eval-form'."
  (let* ((options (consent--interaction-context-options interaction))
         (environment (consent--interaction-context-environment interaction))
         (syntax-environment
          (consent--interaction-context-syntax-environment interaction))
         (program-output-port
          (consent--interaction-context-program-output-port interaction))
         (program-input-port
          (consent--interaction-context-program-input-port interaction))
         (context (consent--new-eval-context options)))
    (setf (consent--port-contents program-output-port) "")
    (setf (consent--eval-context-syntax-environment context)
          syntax-environment)
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (setf (consent--eval-context-current-output-port context)
          program-output-port)
    (when program-input-port
      (setf (consent--eval-context-current-input-port context)
            program-input-port))
    (condition-case condition
        (let ((value
               (consent--trampoline
                (consent--make-sequence (list form) t)
                environment context)))
          (consent-capability-expire-after-eval! context)
          (consent--ok-result-datum value context))
      (error
       (consent-capability-expire-after-eval! context)
       (consent--condition-result-datum condition context)))))

(provide 'consent-eval)

;;; consent-eval.el ends here
