;;; Portable Consent Scheme secrets and redaction policy.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral redaction datum model.  Host adapters
;;; apply the same model at audit, transcript, memory, provider, and resource
;;; disclosure boundaries.

(define-library (agent redaction)
  (export secret-source?
          redact
          context-local-only!
          redaction-log
          safe-for-provider?
          consent-redaction-clear!)
  (import (scheme base)
          (scheme char)
          (prefix (agent redaction-kernel) redaction-kernel:)
          (prefix (agent redaction-state) redaction-state:)
          (only (consent identity-map)
                consent-make-identity-map
                consent-identity-map-ref
                consent-identity-map-set!
                consent-identity-map-release!))
  (begin
    ;; Text used in place of secret values.
    (define redaction-replacement
      redaction-state:redaction-state-replacement)

    ;; Text used in place of withheld local-only context.
    (define local-only-replacement
      redaction-state:redaction-state-local-only-replacement)

    ;; Source labels that often carry secrets or private context.
    (define secret-prone-sources
      '(env
        environment
        auth-source
        local-config
        provider-credentials
        provider-credential
        private-buffer
        shell-output
        process-output
        vcs-remote
        transcript
        memory
        audit-log
        skill-resource))

    (define (member-equal? value list)
      "Return #t when VALUE is in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (name-string value)
      "Return VALUE as a plain string name when it is name-like."
      (cond
       ((symbol? value) (symbol->string value))
       ((string? value) value)
       (else #f)))

    (define (string-downcase* text)
      "Lowercase TEXT for case-insensitive field-name checks."
      (list->string
       (map char-downcase (string->list text))))

    (define (string-prefix-at? text start prefix)
      "Return #t when PREFIX begins at START in TEXT."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and
         (<= (+ start prefix-length) text-length)
         (let match ((index 0))
           (or (= index prefix-length)
               (and
                (char=? (string-ref text (+ start index))
                        (string-ref prefix index))
                (match (+ index 1))))))))

    (define (string-contains? haystack needle)
      "Return #t when NEEDLE occurs in HAYSTACK."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (cond
           ((> (+ index needle-length) haystack-length) #f)
           ((string-prefix-at? haystack index needle) #t)
           (else (loop (+ index 1)))))))

    (define (sensitive-name? name)
      "Return #t when NAME looks like a sensitive field name."
      (if (not name)
          #f
          (let ((lower (string-downcase* name)))
            (or (string-contains? lower "api_key")
                (string-contains? lower "api-key")
                (string-contains? lower "auth")
                (string-contains? lower "bearer")
                (string-contains? lower "credential")
                (string-contains? lower "oauth")
                (string-contains? lower "passphrase")
                (string-contains? lower "password")
                (string-contains? lower "private-key")
                (string-contains? lower "private_key")
                (string-contains? lower "secret")
                (string-contains? lower "session-cookie")
                (string-contains? lower "session_cookie")
                (string-contains? lower "token")))))

    (define (secret-string? text)
      "Return #t when TEXT contains a recognizable secret spelling."
      (and (string? text)
           (redaction-kernel:redaction-kernel-secret-string? text)))

    (define (record-head datum)
      "Return DATUM's record head or #f for association-list payloads."
      (if (and (pair? datum)
               (not (and (pair? (car datum))
                         (symbol? (caar datum))))
               (symbol? (car datum)))
          (car datum)
          #f))

    (define (pair-spine-cycle-shape value)
      "Return VALUE's cdr-cycle `(prefix . period)', or #f."
      (if (not (pair? value))
          #f
          (let detect ((slow value) (fast value))
            (let ((fast-one (cdr fast)))
              (if (not (pair? fast-one))
                  #f
                  (let ((slow-one (cdr slow))
                        (fast-two (cdr fast-one)))
                    (if (not (pair? fast-two))
                        #f
                        (if (eq? slow-one fast-two)
                            (let entry ((left value)
                                        (right slow-one)
                                        (prefix 0))
                              (if (eq? left right)
                                  (let period ((cursor (cdr left))
                                               (length 1))
                                    (if (eq? cursor left)
                                        (cons prefix length)
                                        (period (cdr cursor)
                                                (+ length 1))))
                                  (entry (cdr left)
                                         (cdr right)
                                         (+ prefix 1))))
                            (detect slow-one fast-two)))))))))

    (define (field-values datum)
      "Return field pairs from DATUM after one pass per cdr identity."
      (if (not (pair? datum))
          '()
          (let* ((fields (if (and (pair? (car datum))
                                  (symbol? (caar datum)))
                             datum
                             (cdr datum)))
                 (shape (pair-spine-cycle-shape fields))
                 (limit (and shape (+ (car shape) (cdr shape)))))
            (let loop ((cursor fields) (remaining limit) (result '()))
              (cond
               ((or (null? cursor)
                    (not (pair? cursor))
                    (and remaining (= remaining 0)))
                (reverse result))
               ((and (pair? (car cursor))
                     (symbol? (caar cursor)))
                (loop (cdr cursor)
                      (and remaining (- remaining 1))
                      (cons (car cursor) result)))
               (else
                (loop (cdr cursor)
                      (and remaining (- remaining 1))
                      result)))))))

    (define (field-name field)
      "Return FIELD's name."
      (car field))

    (define (field-main-value field)
      "Return FIELD's first value, or #f."
      (let ((rest (cdr field)))
        (cond
         ((null? rest) #f)
         ((and (pair? rest) (null? (cdr rest))) (car rest))
         (else rest))))

    (define (field-value datum name)
      "Return field NAME from DATUM, or #f."
      (let loop ((fields (field-values datum)))
        (cond
         ((null? fields) #f)
         ((eq? (field-name (car fields)) name)
          (field-main-value (car fields)))
         (else (loop (cdr fields))))))

    (define (source-name datum)
      "Return source name for DATUM, if any."
      (let ((source-field (field-value datum 'source))
            (head (record-head datum)))
        (cond
         ((and (pair? source-field) (symbol? (car source-field)))
          (car source-field))
         ((symbol? source-field) source-field)
         ((and head (member-equal? head secret-prone-sources)) head)
         ((and (eq? head 'buffer) (field-value datum 'private))
          'private-buffer)
         (else #f))))

    (define (sensitive-field-name datum)
      "Return sensitive field name in DATUM, or #f."
      (let ((declared (field-value datum 'field)))
        (if (sensitive-name? (name-string declared))
            (name-string declared)
            (let loop ((fields (field-values datum)))
              (cond
               ((null? fields) #f)
               ((sensitive-name?
                 (symbol->string (field-name (car fields))))
                (symbol->string (field-name (car fields))))
               (else (loop (cdr fields))))))))

    (define (record-secret-value? datum)
      "Return #t when any string field in DATUM looks secret."
      (let loop ((fields (field-values datum)))
        (cond
         ((null? fields) #f)
         ((secret-string? (field-main-value (car fields))) #t)
         (else (loop (cdr fields))))))

    (define (redaction-record? datum)
      "Return #t when DATUM is already a redaction/log record."
      (let ((head (record-head datum)))
        (or (eq? head 'redaction)
            (eq? head 'redaction-log))))

    (define (self-secret-source? datum)
      "Return #t when DATUM itself describes a secret source."
      (if (and (pair? datum)
               (not (redaction-record? datum))
               (let ((source (source-name datum))
                     (field (sensitive-field-name datum)))
                 (or (and (eq? source 'auth-source) field)
                     (and (member-equal? source
                                         '(provider-credentials
                                           provider-credential
                                           private-buffer))
                          (or field
                              (record-secret-value? datum)
                              (eq? source 'private-buffer)))
                     (and (member-equal? source secret-prone-sources)
                          (or field (record-secret-value? datum))))))
          #t
          #f))

    (define (self-local-only? datum)
      "Return #t when DATUM itself is local-only."
      (or (eq? (record-head datum) 'local-only)
          (and (pair? datum) (field-value datum 'local-only))))

    (define (record-for-datum datum)
      "Return a redaction record for DATUM and log it."
      (redaction-state:redaction-state-record-secret!
        (source-name datum)
        (sensitive-field-name datum)))

    (define (graph-contains? datum scalar? pair-self?)
      "Return whether DATUM's finite identity graph satisfies a predicate."
      (cond
       ((redaction-record? datum) #f)
       ((scalar? datum) #t)
       ((not (or (pair? datum) (vector? datum))) #f)
       (else
        (let ((seen (consent-make-identity-map 'redaction-search)))
          (define (walk value)
            (cond
             ((redaction-record? value) #f)
             ((scalar? value) #t)
             ((pair? value)
              (if (consent-identity-map-ref seen value #f)
                  #f
                  (begin
                    (consent-identity-map-set! seen value #t)
                    (or (pair-self? value)
                        (walk (car value))
                        (walk (cdr value))))))
             ((vector? value)
              (if (consent-identity-map-ref seen value #f)
                  #f
                  (begin
                    (consent-identity-map-set! seen value #t)
                    (let loop ((index 0))
                      (and (< index (vector-length value))
                           (or (walk (vector-ref value index))
                               (loop (+ index 1))))))))
             (else #f)))
          (dynamic-wind
           (lambda () #t)
           (lambda () (walk datum))
           (lambda () (consent-identity-map-release! seen)))))))

    (define (local-only? datum)
      "Return #t when DATUM contains local-only context."
      (graph-contains? datum (lambda (value) #f) self-local-only?))

    (define (secret-source? datum)
      "Return #t when DATUM contains secret-prone source data."
      #((parameters
         (datum . "Scheme-readable value to inspect recursively."))
        (returns (type boolean)
         (description
          ("#t when DATUM appears to contain a secret or secret-prone"
            "source marker; otherwise #f.")))
        (effects pure))
      (graph-contains? datum secret-string? self-secret-source?))

    (define (redact datum policy)
      "Return DATUM with secret and local-only content redacted."
      #((parameters
         (datum . "Scheme-readable value to sanitize recursively.")
         (policy
          . ("Redaction policy datum reserved for host-specific policy"
             "choices.")))
        (returns
         . ("DATUM with secret-like values and local-only context"
            "replaced by safe public records."))
        (effects state-write))
      (if (not (or (pair? datum) (vector? datum)))
          (redaction-state:redaction-state-redact-scalar datum)
          (let ((copies (consent-make-identity-map 'redaction-copy))
                (absent (vector 'redaction-copy-absent)))
            (define (walk value)
              (let ((known
                     (if (or (pair? value) (vector? value))
                         (consent-identity-map-ref copies value absent)
                         absent)))
                (if (not (eq? known absent))
                    known
                    (cond
                     ((redaction-record? value) value)
                     ((and (string? value) (secret-string? value))
                      (redaction-state:redaction-state-redact-scalar value))
                     ((and (pair? value) (self-secret-source? value))
                      (let ((record (record-for-datum value)))
                        (consent-identity-map-set! copies value record)
                        record))
                     ((and (pair? value) (self-local-only? value))
                      (let* ((reason
                              (or (field-value value 'reason)
                                  "local-only context"))
                             (record
                              (list 'local-only
                                    (list 'reason reason)
                                    (list 'datum local-only-replacement))))
                        (redaction-state:redaction-state-record-local-only!
                         reason)
                        (consent-identity-map-set! copies value record)
                        record))
                     ((pair? value)
                      (let ((copy (cons #f #f)))
                        (consent-identity-map-set! copies value copy)
                        (set-car! copy (walk (car value)))
                        (set-cdr! copy (walk (cdr value)))
                        copy))
                     ((vector? value)
                      (let* ((length (vector-length value))
                             (copy (make-vector length #f)))
                        (consent-identity-map-set! copies value copy)
                        (let loop ((index 0))
                          (if (< index length)
                              (begin
                                (vector-set!
                                 copy index (walk (vector-ref value index)))
                                (loop (+ index 1)))))
                        copy))
                     (else value)))))
            (dynamic-wind
             (lambda () #t)
             (lambda () (walk datum))
             (lambda () (consent-identity-map-release! copies))))))

    (define (context-local-only! datum reason)
      "Wrap DATUM as local-only context."
      #((parameters
         (datum
          . ("Context value that should not leave the local host"
             "boundary."))
         (reason (type string)
          (description "Human-readable reason for withholding DATUM.")))
        (returns (type local-only)
         (description
           "A `local-only` wrapper datum carrying REASON and DATUM."))
        (effects state-write))
      (redaction-state:redaction-state-record-local-only! reason)
      (list 'local-only
            (list 'reason reason)
            (list 'datum datum)))

    (define (redaction-log . options)
      "Return recent redaction records as a Scheme-readable datum."
      #((parameters
         (options (type list)
          (description
            ("Reserved option list for future filtering or pagination."))))
        (returns (type redaction-log)
         (description
          ("A `redaction-log` datum containing recent redaction"
            "records.")))
        (effects state-read))
      (list 'redaction-log
            (list 'records
                  (redaction-state:redaction-state-records))))

    (define (consent-redaction-clear!)
      "Clear the process-local redaction log."
      #((parameters)
        (returns
         . ("An unspecified value after clearing the process-local"
            "redaction records."))
        (effects state-write))
      (redaction-state:redaction-state-clear!))

    (define (safe-for-provider? datum provider)
      "Return #t when DATUM can be sent to PROVIDER without redaction."
      #((parameters
         (datum . "Scheme-readable value to inspect recursively.")
         (provider
          . ("Provider identifier or metadata reserved for"
             "provider-specific policy.")))
        (returns (type boolean)
         (description
          ("#t when DATUM has no detected secret or local-only"
            "content; otherwise #f.")))
        (effects pure))
      ;; Local-only context records carry an explicit top-level marker. Check
      ;; it first so provider admission can reject them without needlessly
      ;; walking opaque handles and the rest of a potentially large context.
      (and (not (local-only? datum))
           (not (secret-source? datum))))))
