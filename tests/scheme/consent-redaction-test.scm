;;; Portable Agent Redaction semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (agent redaction)
        (testing harness)
        (stdlib testing)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing)
        (stdlib eager-comprehensions)
        (stdlib lightweight-testing))

(define (field-value datum name)
  "Return field NAME from DATUM, or false."
  (let loop ((fields (if (pair? datum) (cdr datum) '())))
    (cond
     ((null? fields) #f)
     ((and (pair? (car fields)) (eq? (caar fields) name))
      (cadr (car fields)))
     (else (loop (cdr fields))))))

(testing-harness-run "Agent Redaction portable semantics"
  (consent-redaction-clear!)
  (let* ((secret '((source env)
                   (field "OPENAI_API_KEY")
                   (value "sk-portablesecret1234567890")))
         (redacted (redact secret 'remote-provider)))
    (test-assert "secret source" (secret-source? secret))
    (test-equal "redaction record" 'redaction (car redacted))
    (test-equal "redaction kind" 'secret (field-value redacted 'kind))
    (test-equal "redaction replacement" "[redacted]"
                (field-value redacted 'replacement))
    (test-equal "redaction policy" 'local-only
                (field-value redacted 'policy))
    (test-assert "secret unsafe for provider"
                 (not (safe-for-provider? secret 'openai))))
  (let ((local (context-local-only! '((text "private")) "private buffer")))
    (test-equal "local-only record" 'local-only (car local))
    (test-equal "local-only reason" "private buffer"
                (field-value local 'reason))
    (test-assert "local context unsafe"
                 (not (safe-for-provider? local 'openai))))
  (test-equal "ordinary dotted datum remains unchanged"
              '(procedure first . rest)
              (redact '(procedure first . rest) 'debugger))
  (test-assert "ordinary data is safe"
               (safe-for-provider? '((answer 42)) 'openai))
  (test-assert "redaction log records decisions"
               (pair? (cdr (redaction-log))))
  (test-property
   (lambda (text)
     (equal? text (redact text 'debugger)))
   (list (make-random-string-generator 12 "abcxyz"))
   25)
  (testing-harness-check
   "lightweight eager safe-datum table" 1
   (check-ec (:list datum '((answer 42) (status ok) (items (1 2 3))))
             (safe-for-provider? datum 'openai)
             => #t
             (datum))))
