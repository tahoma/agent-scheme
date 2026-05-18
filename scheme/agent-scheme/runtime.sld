;;; Portable Agent Scheme runtime boundary facade.
;;;
;;; This library exposes runtime value and environment entry points while the
;;; portable bootstrap implementation still lives in `(agent-scheme eval)'.

(define-library (agent-scheme runtime)
  (export agent-scheme-make-empty-environment
          agent-scheme-unspecified
          agent-scheme-unspecified?
          agent-scheme-procedure?
          agent-scheme-primitive-procedure?)
  (import (agent-scheme eval)))
