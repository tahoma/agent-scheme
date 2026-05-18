;;; Portable Agent Scheme interpreter boundary facade.
;;;
;;; This library exposes interpreter entry points while the portable bootstrap
;;; implementation still lives in `(agent-scheme eval)'.

(define-library (agent-scheme interpreter)
  (export agent-scheme-eval
          agent-scheme-eval-source
          agent-scheme-eval-string
          agent-scheme-eval-result
          agent-scheme-eval-source-result
          agent-scheme-result->external
          agent-scheme-value->external)
  (import (agent-scheme eval)))
