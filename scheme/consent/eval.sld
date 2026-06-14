;;; Portable R7RS evaluator facade for Consent Scheme.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; The portable pass modules own runtime state, result rendering, base-library
;;; metadata, library resolution, macro expansion, and interpreter execution.
;;; This library preserves the original public import surface.

(define-library (consent eval)
  (export consent-eval
          consent-eval-source
          consent-eval-string
          consent-expand
          consent-expand-source
          consent-eval-result
          consent-eval-source-result
          consent-make-interaction-context
          consent-interaction-context?
          consent-interaction-context-session-id
          consent-interaction-program-output
          consent-interaction-eval-form
          consent-interaction-program-input-port
          consent-interaction-seed-program-input!
          consent-interaction-program-input-remainder
          consent-program-input-from-string
          consent-make-empty-environment
          consent-make-base-environment
          consent-base-primitive-names
          consent-base-primitive-specs
          consent-base-prelude-binding-names
          consent-base-prelude-binding-specs
          consent-base-binding-specs
          consent-standard-source-library-specs
          consent-primitive-manifest-binding-specs
          consent-result->external
          consent-value->external
          consent-unspecified
          consent-unspecified?
          consent-procedure?
          consent-primitive-procedure?)
  (import (consent interpreter)))
