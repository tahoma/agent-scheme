;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; Portable Agent Scheme context record helpers.
;;;
;;; This library owns host-neutral context record construction. Host adapters
;;; may add live observations, but Scheme-visible context remains ordinary
;;; printable datums.

(define-library (agent-scheme context)
  (export context-field
          context-present?
          make-request-context
          make-conversation-summary
          make-focus-context
          make-context-bundle)
  (import (scheme base))
  (begin
    (define (context-field name value)
      "Return a Scheme-readable context field named NAME with VALUE."
      #((parameters . ((name . "Symbol naming the context field.")
                       (value . "Scheme-readable field value.")))
        (returns . "A two-element context field list.")
        (effects . (pure)))
      (list name value))

    (define (context-present? value)
      "Return #t when VALUE is present in a context bundle."
      #((parameters . ((value . "Optional context value to check.")))
        (returns . "#t when VALUE is not #f; otherwise #f.")
        (effects . (pure)))
      (not (eq? value #f)))

    (define (context-present-records records)
      "Return RECORDS without absent #f entries, preserving order."
      (let loop ((rest records) (kept '()))
        (cond
         ((null? rest) (reverse kept))
         ((context-present? (car rest))
          (loop (cdr rest) (cons (car rest) kept)))
         (else (loop (cdr rest) kept)))))

    (define (make-request-context request-id session-id request)
      "Return a request-context record, or #f when no request fields exist."
      #((parameters . ((request-id . "Optional request id.")
                       (session-id . "Optional session id.")
                       (request . "Optional request payload datum.")))
        (returns . "A `request-context` datum containing present fields, or #f.")
        (effects . (pure)))
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
      #((parameters . ((session-id . "Optional session id associated with the summary.")
                       (summary . "Conversation summary text or datum.")))
        (returns . "A `conversation-summary` datum, or #f when SUMMARY is #f.")
        (effects . (pure)))
      (if summary
          (append
           (list 'conversation-summary)
           (if session-id
               (list (context-field 'session-id session-id))
               '())
           (list (context-field 'summary summary)))
          #f))

    (define (make-focus-context records)
      "Return a focus-context from RECORDS, or #f when all records are absent."
      #((parameters . ((records . "List of optional context records.")))
        (returns . "A `focus-context` datum containing present records, or #f.")
        (effects . (pure)))
      (let ((present (context-present-records records)))
        (if (null? present)
            #f
            (cons 'focus-context present))))

    (define (make-context-bundle records)
      "Return a context bundle from RECORDS."
      #((parameters . ((records . "List of optional context records.")))
        (returns . "A `context` datum containing only present records.")
        (effects . (pure)))
      (cons 'context (context-present-records records)))))
