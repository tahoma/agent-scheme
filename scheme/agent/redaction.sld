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
          (prefix (stdlib generator) gen:))
  (begin
    ;; Text used in place of secret values.
    (define redaction-replacement "[redacted]")

    ;; Text used in place of withheld local-only context.
    (define local-only-replacement "[local-only]")

    ;; Recent redaction decisions, newest first.
    (define redaction-records '())

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

    (define (string-contains? haystack needle)
      "Return #t when NEEDLE occurs in HAYSTACK."
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (cond
           ((> (+ index needle-length) haystack-length) #f)
           ((string=? (substring haystack index (+ index needle-length))
                      needle)
            #t)
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
           (or (string-contains? text "sk-")
               (string-contains? text "ghp_")
               (string-contains? text "gho_")
               (string-contains? text "ghu_")
               (string-contains? text "ghs_")
               (string-contains? text "ghr_")
               (string-contains? text "xox")
               (string-contains? text "AKIA")
               (string-contains? text "PRIVATE KEY"))))

    (define (record-head datum)
      "Return DATUM's record head or #f for association-list payloads."
      (if (and (pair? datum)
               (not (and (pair? (car datum))
                         (symbol? (caar datum))))
               (symbol? (car datum)))
          (car datum)
          #f))

    (define (field-values datum)
      "Return field pairs from DATUM."
      (if (not (pair? datum))
          '()
          (let ((fields (if (and (pair? (car datum))
                                 (symbol? (caar datum)))
                            datum
                            (cdr datum))))
            (let loop ((cursor fields) (result '()))
              (cond
               ((null? cursor) (reverse result))
               ((not (pair? cursor)) (reverse result))
               ((and (pair? (car cursor))
                     (symbol? (caar cursor)))
                (loop (cdr cursor) (cons (car cursor) result)))
               (else (loop (cdr cursor) result)))))))

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

    (define (make-redaction-record kind source field policy)
      "Build a redaction record."
      (list 'redaction
            (list 'kind kind)
            (list 'source (if source source 'unknown))
            (list 'field (if field field "value"))
            (list 'replacement redaction-replacement)
            (list 'policy policy)))

    (define (make-local-only-record reason)
      "Build a local-only redaction record."
      (list 'redaction
            (list 'kind 'local-only)
            (list 'source 'local-only)
            (list 'field "datum")
            (list 'replacement local-only-replacement)
            (list 'policy 'local-only)
            (list 'reason reason)))

    (define (remember! record)
      "Remember RECORD in the process-local redaction log."
      (set! redaction-records (cons record redaction-records))
      record)

    (define (record-for-datum datum)
      "Return a redaction record for DATUM and log it."
      (remember!
       (make-redaction-record
        'secret
        (source-name datum)
        (sensitive-field-name datum)
        'local-only)))

    (define (local-only? datum)
      "Return #t when DATUM contains local-only context."
      (cond
       ((redaction-record? datum) #f)
       ((pair? datum)
        (or (self-local-only? datum)
            (local-only? (car datum))
            (local-only? (cdr datum))))
       ((vector? datum)
        (gen:generator-any local-only? (gen:vector->generator datum)))
       (else #f)))

    (define (secret-source? datum)
      "Return #t when DATUM contains secret-prone source data."
      #((parameters
         (datum . "Scheme-readable value to inspect recursively."))
        (returns (type boolean)
         (description
          ("#t when DATUM appears to contain a secret or secret-prone"
            "source marker; otherwise #f.")))
        (effects pure))
      (cond
       ((redaction-record? datum) #f)
       ((string? datum) (secret-string? datum))
       ((pair? datum)
        (or (self-secret-source? datum)
            (secret-source? (car datum))
            (secret-source? (cdr datum))))
       ((vector? datum)
        (gen:generator-any secret-source? (gen:vector->generator datum)))
       (else #f)))

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
      (cond
       ((redaction-record? datum) datum)
       ((and (string? datum) (secret-string? datum))
        (remember! (make-redaction-record 'secret 'string "value" 'local-only))
        redaction-replacement)
       ((self-secret-source? datum)
        (record-for-datum datum))
       ((self-local-only? datum)
        (let ((reason (or (field-value datum 'reason) "local-only context")))
          (remember! (make-local-only-record reason))
          (list 'local-only
                (list 'reason reason)
                (list 'datum local-only-replacement))))
       ((pair? datum)
        (cons (redact (car datum) policy)
              (redact (cdr datum) policy)))
       ((vector? datum)
        (gen:generator->vector
         (gen:gmap
          (lambda (value) (redact value policy))
          (gen:vector->generator datum))))
       (else datum)))

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
      (remember! (make-local-only-record reason))
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
            (list 'records redaction-records)))

    (define (consent-redaction-clear!)
      "Clear the process-local redaction log."
      #((parameters)
        (returns
         . ("An unspecified value after clearing the process-local"
            "redaction records."))
        (effects state-write))
      (set! redaction-records '()))

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
