;;; Portable Agent Scheme library-resolution boundary facade.
;;;
;;; This library exposes source-library metadata while the portable bootstrap
;;; implementation still lives in `(agent-scheme eval)'.

(define-library (agent-scheme library)
  (export agent-scheme-standard-source-library-specs)
  (import (agent-scheme eval)))
