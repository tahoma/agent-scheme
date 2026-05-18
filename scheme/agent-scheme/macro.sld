;;; Portable Agent Scheme macro-expansion boundary facade.
;;;
;;; This library exposes macro-expansion entry points while the portable
;;; bootstrap implementation still lives in `(agent-scheme eval)'.

(define-library (agent-scheme macro)
  (export agent-scheme-expand
          agent-scheme-expand-source)
  (import (agent-scheme eval)))
