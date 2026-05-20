;;; Portable Agent Scheme secrets and redaction policy.
;;;
;;; This library owns the host-neutral redaction datum model.  Host adapters
;;; apply the same model at audit, transcript, memory, provider, and resource
;;; disclosure boundaries.

(define-library (agent-scheme redaction)
  (export secret-source?
          redact
          context-local-only!
          redaction-log
          safe-for-provider?
          agent-scheme-redaction-clear!)
  (import (scheme base)
          (scheme char))
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

    ;; Return #t when VALUE is in LIST using equal?.
    (define (member-equal? value list)
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    ;; Return VALUE as a plain string name when it is name-like.
    (define (name-string value)
      (cond
       ((symbol? value) (symbol->string value))
       ((string? value) value)
       (else #f)))

    ;; Lowercase TEXT for case-insensitive field-name checks.
    (define (string-downcase* text)
      (list->string
       (map char-downcase (string->list text))))

    ;; Return #t when NEEDLE occurs in HAYSTACK.
    (define (string-contains? haystack needle)
      (let ((haystack-length (string-length haystack))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (cond
           ((> (+ index needle-length) haystack-length) #f)
           ((string=? (substring haystack index (+ index needle-length))
                      needle)
            #t)
           (else (loop (+ index 1)))))))

    ;; Return #t when NAME looks like a sensitive field name.
    (define (sensitive-name? name)
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

    ;; Return #t when TEXT contains a recognizable secret spelling.
    (define (secret-string? text)
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

    ;; Return DATUM's record head or #f for association-list payloads.
    (define (record-head datum)
      (if (and (pair? datum)
               (not (and (pair? (car datum))
                         (symbol? (caar datum))))
               (symbol? (car datum)))
          (car datum)
          #f))

    ;; Return field pairs from DATUM.
    (define (field-values datum)
      (if (not (pair? datum))
          '()
          (let ((fields (if (and (pair? (car datum))
                                 (symbol? (caar datum)))
                            datum
                            (cdr datum))))
            (let loop ((cursor fields) (result '()))
              (cond
               ((null? cursor) (reverse result))
               ((and (pair? (car cursor))
                     (symbol? (caar cursor)))
                (loop (cdr cursor) (cons (car cursor) result)))
               (else (loop (cdr cursor) result)))))))

    ;; Return FIELD's name.
    (define (field-name field)
      (car field))

    ;; Return FIELD's first value, or #f.
    (define (field-main-value field)
      (if (null? (cdr field)) #f (cadr field)))

    ;; Return field NAME from DATUM, or #f.
    (define (field-value datum name)
      (let loop ((fields (field-values datum)))
        (cond
         ((null? fields) #f)
         ((eq? (field-name (car fields)) name)
          (field-main-value (car fields)))
         (else (loop (cdr fields))))))

    ;; Return source name for DATUM, if any.
    (define (source-name datum)
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

    ;; Return sensitive field name in DATUM, or #f.
    (define (sensitive-field-name datum)
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

    ;; Return #t when any string field in DATUM looks secret.
    (define (record-secret-value? datum)
      (let loop ((fields (field-values datum)))
        (cond
         ((null? fields) #f)
         ((secret-string? (field-main-value (car fields))) #t)
         (else (loop (cdr fields))))))

    ;; Return #t when DATUM is already a redaction/log record.
    (define (redaction-record? datum)
      (let ((head (record-head datum)))
        (or (eq? head 'redaction)
            (eq? head 'redaction-log))))

    ;; Return #t when DATUM itself describes a secret source.
    (define (self-secret-source? datum)
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

    ;; Return #t when DATUM itself is local-only.
    (define (self-local-only? datum)
      (or (eq? (record-head datum) 'local-only)
          (and (pair? datum) (field-value datum 'local-only))))

    ;; Build a redaction record.
    (define (make-redaction-record kind source field policy)
      (list 'redaction
            (list 'kind kind)
            (list 'source (if source source 'unknown))
            (list 'field (if field field "value"))
            (list 'replacement redaction-replacement)
            (list 'policy policy)))

    ;; Build a local-only redaction record.
    (define (make-local-only-record reason)
      (list 'redaction
            (list 'kind 'local-only)
            (list 'source 'local-only)
            (list 'field "datum")
            (list 'replacement local-only-replacement)
            (list 'policy 'local-only)
            (list 'reason reason)))

    ;; Remember RECORD in the process-local redaction log.
    (define (remember! record)
      (set! redaction-records (cons record redaction-records))
      record)

    ;; Return a redaction record for DATUM and log it.
    (define (record-for-datum datum)
      (remember!
       (make-redaction-record
        'secret
        (source-name datum)
        (sensitive-field-name datum)
        'local-only)))

    ;; Return #t when DATUM contains local-only context.
    (define (local-only? datum)
      (cond
       ((redaction-record? datum) #f)
       ((pair? datum)
        (or (self-local-only? datum)
            (local-only? (car datum))
            (local-only? (cdr datum))))
       ((vector? datum)
        (let loop ((values (vector->list datum)))
          (cond
           ((null? values) #f)
           ((local-only? (car values)) #t)
           (else (loop (cdr values))))))
       (else #f)))

    ;; Return #t when DATUM contains secret-prone source data.
    (define (secret-source? datum)
      (cond
       ((redaction-record? datum) #f)
       ((string? datum) (secret-string? datum))
       ((pair? datum)
        (or (self-secret-source? datum)
            (secret-source? (car datum))
            (secret-source? (cdr datum))))
       ((vector? datum)
        (let loop ((values (vector->list datum)))
          (cond
           ((null? values) #f)
           ((secret-source? (car values)) #t)
           (else (loop (cdr values))))))
       (else #f)))

    ;; Return DATUM with secret and local-only content redacted.
    (define (redact datum policy)
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
        (list->vector (map (lambda (value) (redact value policy))
                           (vector->list datum))))
       (else datum)))

    ;; Wrap DATUM as local-only context.
    (define (context-local-only! datum reason)
      (remember! (make-local-only-record reason))
      (list 'local-only
            (list 'reason reason)
            (list 'datum datum)))

    ;; Return recent redaction records as a Scheme-readable datum.
    (define (redaction-log . options)
      (list 'redaction-log
            (list 'records redaction-records)))

    ;; Clear the process-local redaction log.
    (define (agent-scheme-redaction-clear!)
      (set! redaction-records '()))

    ;; Return #t when DATUM can be sent to PROVIDER without redaction.
    (define (safe-for-provider? datum provider)
      (and (not (secret-source? datum))
           (not (local-only? datum))))))
