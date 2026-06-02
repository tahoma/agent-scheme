;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; Portable R7RS evaluator facade for Agent Scheme.
;;;
;;; The portable pass modules own runtime state, result rendering, base-library
;;; metadata, library resolution, macro expansion, and interpreter execution.
;;; This library preserves the original public import surface.

(define-library (agent-scheme eval)
  (export agent-scheme-eval
          agent-scheme-eval-source
          agent-scheme-eval-string
          agent-scheme-expand
          agent-scheme-expand-source
          agent-scheme-eval-result
          agent-scheme-eval-source-result
          agent-scheme-make-empty-environment
          agent-scheme-make-base-environment
          agent-scheme-base-primitive-names
          agent-scheme-base-primitive-specs
          agent-scheme-base-prelude-binding-names
          agent-scheme-base-prelude-binding-specs
          agent-scheme-base-binding-specs
          agent-scheme-standard-source-library-specs
          agent-scheme-primitive-manifest-binding-specs
          agent-scheme-result->external
          agent-scheme-value->external
          agent-scheme-unspecified
          agent-scheme-unspecified?
          agent-scheme-procedure?
          agent-scheme-primitive-procedure?)
  (import (agent-scheme interpreter)))
