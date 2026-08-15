;;; Shared scalar redaction and process-local decision state.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (agent redaction-state)
  (export redaction-state-replacement
          redaction-state-local-only-replacement
          redaction-state-record-secret!
          redaction-state-record-local-only!
          redaction-state-redact-scalar
          redaction-state-records
          redaction-state-clear!)
  (import (scheme base)
          (prefix (agent redaction-kernel) redaction-kernel:))
  (begin
    ;; Text substituted for a detected secret.
    (define redaction-state-replacement "[redacted]")
    ;; Text substituted for a value that must stay on the local host.
    (define redaction-state-local-only-replacement "[local-only]")
    ;; Recent redaction decisions, newest first.
    (define redaction-state-decisions '())

    (define (redaction-state-remember! record)
      "Remember RECORD and return it."
      (set! redaction-state-decisions
            (cons record redaction-state-decisions))
      record)

    (define (redaction-state-record-secret! source field)
      "Record and return one secret redaction decision."
      #((parameters
         (source (type symbol)
          (description "Source label or `unknown`."))
         (field (type string)
          (description "Redacted field name.")))
        (returns (type redaction)
         (description "Recorded secret redaction decision."))
        (effects allocation state-write))
      (redaction-state-remember!
       (list 'redaction
             (list 'kind 'secret)
             (list 'source (if source source 'unknown))
             (list 'field (if field field "value"))
             (list 'replacement redaction-state-replacement)
             (list 'policy 'local-only))))

    (define (redaction-state-record-local-only! reason)
      "Record and return one local-only redaction decision."
      #((parameters
         (reason (type string)
          (description "Reason that the value must stay local.")))
        (returns (type redaction)
         (description "Recorded local-only redaction decision."))
        (effects allocation state-write))
      (redaction-state-remember!
       (list 'redaction
             (list 'kind 'local-only)
             (list 'source 'local-only)
             (list 'field "datum")
             (list 'replacement redaction-state-local-only-replacement)
             (list 'policy 'local-only)
             (list 'reason reason))))

    (define (redaction-state-redact-scalar datum)
      "Return scalar DATUM with a secret string redacted and recorded."
      #((parameters
         (datum (type any)
          (description "Scalar value to sanitize.")))
        (returns (type any)
         (description "DATUM or the configured secret replacement."))
        (effects allocation state-write))
      (if (and (string? datum)
               (redaction-kernel:redaction-kernel-secret-string? datum))
          (begin
            (redaction-state-record-secret! 'string "value")
            redaction-state-replacement)
          datum))

    (define (redaction-state-records)
      "Return the process-local redaction decisions, newest first."
      #((parameters)
        (returns (type list)
         (description "Current redaction decision records."))
        (effects state-read))
      redaction-state-decisions)

    (define (redaction-state-clear!)
      "Clear the process-local redaction decisions."
      #((parameters)
        (returns (type unspecified)
         (description "Unspecified value after clearing decisions."))
        (effects state-write))
      (set! redaction-state-decisions '()))))
