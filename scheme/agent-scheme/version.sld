;;; Portable Agent Scheme version data.
;;;
;;; This library is the single source of truth for the Agent Scheme runtime
;;; version number. Host adapters and portable runtime modules derive their
;;; public version APIs from this Scheme-readable datum instead of repeating
;;; numeric components in implementation source.

(define-library (agent-scheme version)
  (export agent-scheme-version-datum)
  (import (scheme base))
  (begin
    ;; Define the canonical Agent Scheme version datum.
    (define agent-scheme-version-datum
      '(agent-scheme-version 0 14 1))))
