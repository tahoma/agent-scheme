;;; consent-repl.scm --- Portable terminal REPL shell entrypoint
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Minimal portable entrypoint for the terminal REPL shell
;;; (docs/portable-repl.md).  Run under any supported R7RS host with the
;;; repository `scheme/' directory on the library search path, it reads Consent
;;; Scheme forms incrementally from stdin, evaluates them in a durable authorized
;;; session, and writes the cross-host REPL interaction contract record stream
;;; (docs/repl-interaction-contract.md) to the diagnostic stream, keeping the
;;; program output stream clean for scripted use.
;;;
;;; This is the first interactive non-Emacs entrypoint.  All loop logic lives in
;;; (cli repl-shell); this program only wires the library to the host command
;;; line.

(import (cli repl-shell))

(cli-repl-main)
