;;; consent-native-cli.scm --- Portable native CLI process-boundary entrypoint
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Minimal portable entrypoint for the native CLI and daemon host adapter
;;; (docs/native-cli-daemon-adapter.md). Run under any supported R7RS host with
;;; the repository `scheme/' directory on the library search path, it crosses a
;;; real process boundary and writes the Scheme-readable boundary record stream
;;; to stdout; approval prompts and diagnostics go to the diagnostic stream.
;;;
;;; This is the non-Emacs entrypoint the portable terminal REPL shell builds
;;; on.
;;; All adapter logic lives in (cli native-cli); this program only wires the
;;; library to the host command line.

(import (cli native-cli))

(cli-native-cli-main)
