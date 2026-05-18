;;; Portable Agent Scheme base-library boundary facade.
;;;
;;; This library exposes `(scheme base)' bootstrap metadata while the portable
;;; bootstrap implementation still lives in `(agent-scheme eval)'.

(define-library (agent-scheme base)
  (export agent-scheme-make-base-environment
          agent-scheme-base-primitive-names
          agent-scheme-base-primitive-specs
          agent-scheme-base-prelude-binding-names
          agent-scheme-base-prelude-binding-specs
          agent-scheme-base-binding-specs
          agent-scheme-primitive-manifest-binding-specs)
  (import (agent-scheme eval)))
