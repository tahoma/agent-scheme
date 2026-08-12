;;; Portable Agent Redaction semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (agent redaction)
        (prefix (agent redaction-kernel) redaction-kernel:)
        (testing harness)
        (testing registry)
        (testing runner)
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

(testing-registry-case
 'redaction-secrets '(agent redaction security)
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
   (test-assert
    "all fixed secret spellings are recognized at string boundaries"
    (and (secret-source? "sk-x")
         (secret-source? "prefix ghp_x")
         (secret-source? "gho_x suffix")
         (secret-source? "prefix ghu_x")
         (secret-source? "ghs_x suffix")
         (secret-source? "prefix ghr_x")
         (secret-source? "xox-secret")
         (secret-source? "AKIA-secret")
         (secret-source? "prefix PRIVATE KEY")
         (not (secret-source? "prefix ghq_x"))
         (not (secret-source? "SK-x"))
         (not (secret-source? "prefix PRIVATE KE"))))
   (let* ((long-prefix (make-string 4096 #\z))
          (near-miss
           (list (list 'source 'env)
                 (list 'field (string-append long-prefix "credentiax"))
                 (list 'value "ordinary")))
          (contained
           (list (list 'source 'env)
                 (list 'field (string-append long-prefix "credential"))
                 (list 'value "ordinary")))
          (empty-name
           (list (list 'source 'env)
                 (list 'field "")
                 (list 'value "ordinary"))))
     (test-assert "long sensitive-name near miss stays ordinary"
                  (not (secret-source? near-miss)))
     (test-assert "long sensitive-name suffix is recognized"
                  (secret-source? contained))
     (test-assert "empty sensitive field name stays ordinary"
                  (not (secret-source? empty-name))))
   (test-assert "secret unsafe for provider"
                (not (safe-for-provider? secret 'openai)))))

(testing-registry-case
 'redaction-local-context '(agent redaction context)
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
              (pair? (cdr (redaction-log)))))

(testing-registry-case
 'redaction-string-kernel '(agent redaction security boundary)
 (consent-redaction-clear!)
 (let* ((long-prefix (make-string 4096 #\z))
        (variable-width-prefix
         (make-string 16384 (integer->char #x3bb)))
        (huge-variable-width-tail
         (make-string 1048576 (integer->char #x3bb)))
        (early-secret-with-huge-tail
         (string-append "sk-" huge-variable-width-tail))
        (positives
         (list
          "sk-"
          "prefix sk-x"
          "ghp_" "gho_x" "ghu_x" "ghs_x" "ghr_x"
          "xox" "AKIA" "PRIVATE KEY"
          ;; Failed longer candidates retain overlapping live prefixes.
          "ghsk-" "PRIVAKIA"
          (string-append long-prefix "sk-")
          (string-append variable-width-prefix "PRIVATE KEY")
          (string-append "before"
                         (string (integer->char 0))
                         "PRIVATE KEY")))
        (negatives
         (list
          "" "s" "sk" "SK-" "Sk-" "ghp" "ghq_x" "Xox"
          "akia" "PRIVATE KE" "private key"
          (string-append long-prefix "sk")
          (string-append variable-width-prefix "PRIVATE KE"))))
   (test-equal
    "kernel recognizes every exact secret spelling"
    (make-list (length positives) #t)
    (map redaction-kernel:redaction-kernel-secret-string? positives))
   (test-equal
    "kernel rejects partial and case-shifted near misses"
    (make-list (length negatives) #f)
    (map redaction-kernel:redaction-kernel-secret-string? negatives))
   (test-assert
    "kernel accepts an early marker before a huge variable-width tail"
    (redaction-kernel:redaction-kernel-secret-string?
     early-secret-with-huge-tail))
   (test-equal
    "pure kernel calls do not write the redaction log"
    '()
    (field-value (redaction-log) 'records))
   (test-equal
    "source policy still chooses the replacement"
    "[redacted]"
    (redact "prefix sk-x" 'model-diagnostics))
   (test-equal
    "source policy logs exactly one matching decision"
    1
    (length (field-value (redaction-log) 'records)))
   (let ((callback-called? #f))
     (test-assert
      "kernel rejects a procedure without invoking it"
      (guard (condition (else (not callback-called?)))
        (redaction-kernel:redaction-kernel-secret-string?
         (lambda () (set! callback-called? #t)))
        #f)))))

(testing-registry-case
 'redaction-properties '(agent redaction property)
 (test-property
  (lambda (text) (equal? text (redact text 'debugger)))
  (list (make-random-string-generator 12 "abcxyz"))
  25)
 (testing-harness-check
  "lightweight eager safe-datum table" 1
  (check-ec (:list datum '((answer 42) (status ok) (items (1 2 3))))
            (safe-for-provider? datum 'openai)
            => #t
            (datum))))

(testing-runner-main "Agent Redaction portable semantics" (command-line))
