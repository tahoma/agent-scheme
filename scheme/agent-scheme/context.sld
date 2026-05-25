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
    ;; Return a Scheme-readable context field named NAME with VALUE.
    (define (context-field name value)
      (list name value))

    ;; Report whether VALUE is present in a context bundle.
    (define (context-present? value)
      (not (eq? value #f)))

    ;; Return RECORDS without absent #f entries, preserving order.
    (define (context-present-records records)
      (let loop ((rest records) (kept '()))
        (cond
         ((null? rest) (reverse kept))
         ((context-present? (car rest))
          (loop (cdr rest) (cons (car rest) kept)))
         (else (loop (cdr rest) kept)))))

    ;; Return a request-context record, or #f when no request fields exist.
    (define (make-request-context request-id session-id request)
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

    ;; Return a conversation-summary record, or #f when SUMMARY is absent.
    (define (make-conversation-summary session-id summary)
      (if summary
          (append
           (list 'conversation-summary)
           (if session-id
               (list (context-field 'session-id session-id))
               '())
           (list (context-field 'summary summary)))
          #f))

    ;; Return a focus-context from RECORDS, or #f when all records are absent.
    (define (make-focus-context records)
      (let ((present (context-present-records records)))
        (if (null? present)
            #f
            (cons 'focus-context present))))

    ;; Return a context bundle from RECORDS.
    (define (make-context-bundle records)
      (cons 'context (context-present-records records)))))
