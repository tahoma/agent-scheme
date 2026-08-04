;;; Portable Consent Scheme context record helpers.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns host-neutral context record construction. Host adapters
;;; may add live observations, but Scheme-visible context remains ordinary
;;; printable datums.

(define-library (agent context)
  (export context-field
          context-present?
          make-request-context
          make-conversation-summary
          make-focus-context
          make-context-bundle)
  (import (scheme base)
          (only (stdlib list) filter))
  (begin
    (define (context-field name value)
      "Return a Scheme-readable context field named NAME with VALUE."
      #((parameters
         (name (type symbol)
          (description "Symbol naming the context field."))
         (value . "Scheme-readable field value."))
        (returns (type list)
         (description "A two-element context field list."))
        (effects pure))
      (list name value))

    (define (context-present? value)
      "Return #t when VALUE is present in a context bundle."
      #((parameters
         (value . "Optional context value to check."))
        (returns (type boolean)
         (description "#t when VALUE is not #f; otherwise #f."))
        (effects pure))
      (not (eq? value #f)))

    (define (context-present-records records)
      "Return RECORDS without absent #f entries, preserving order."
      (filter context-present? records))

    (define (make-request-context request-id session-id request)
      "Return a request-context record, or #f when no request fields exist."
      #((parameters
         (request-id . "Optional request id.")
         (session-id (type (or symbol boolean))
          (description "Optional session id."))
         (request . "Optional request payload datum."))
        (returns (type (or request-context boolean))
         (description
          ("A `request-context` datum containing present fields, or"
            "#f.")))
        (effects pure))
      (if (or request-id session-id request)
          (append
           (list 'request-context)
           (if request-id
               (list (context-field 'request-id request-id))
               '())
           (if session-id
               (list (context-field 'session-id session-id))
               '())
           (if request
               (list (context-field 'request request))
               '()))
          #f))

    (define (make-conversation-summary session-id summary)
      "Return a conversation-summary record, or #f when SUMMARY is absent."
      #((parameters
         (session-id (type (or symbol boolean))
          (description "Optional session id associated with the summary."))
         (summary (type (or string pair))
          (description "Conversation summary text or datum.")))
        (returns (type (or conversation-summary boolean))
         (description
           "A `conversation-summary` datum, or #f when SUMMARY is #f."))
        (effects pure))
      (if summary
          (append
           (list 'conversation-summary)
           (if session-id
               (list (context-field 'session-id session-id))
               '())
           (list (context-field 'summary summary)))
          #f))

    (define (make-focus-context records)
      "Return a focus-context from RECORDS, or #f when all records are absent.\
"
      #((parameters
         (records (type list)
          (description "List of optional context records.")))
        (returns (type (or focus-context boolean))
         (description
           "A `focus-context` datum containing present records, or #f."))
        (effects pure))
      (let ((present (context-present-records records)))
        (if (null? present)
            #f
            (cons 'focus-context present))))

    (define (make-context-bundle records)
      "Return a context bundle from RECORDS."
      #((parameters
         (records (type list)
          (description "List of optional context records.")))
        (returns (type list)
         (description "A `context` datum containing only present records."))
        (effects pure))
      (cons 'context (context-present-records records)))))
