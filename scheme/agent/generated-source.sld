;;; generated-source.sld --- Portable generated-source candidate loop.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns deterministic generated-source candidate handling for
;;; agentic coding loops. Model transport, sandbox evaluation, and live-session
;;; mutation remain injected boundaries; the library normalizes untrusted text,
;;; reads Scheme datums, records diagnostics, validates caller contracts,
;;; drives
;;; bounded repair attempts, and gates explicit application as Scheme-readable
;;; data.

(define-library (agent generated-source)
  (export generated-source-diagnostic
          generated-source-record-field-value
          generated-source-candidate
          generated-source-candidate?
          generated-source-candidate-status
          generated-source-candidate-source
          generated-source-candidate-original
          generated-source-candidate-forms
          generated-source-candidate-diagnostics
          generated-source-attempt?
          generated-source-run
          generated-source-run?
          generated-source-run-status
          generated-source-run-attempts
          generated-source-run-candidate
          generated-source-run-diagnostics
          generated-source-run-repair-prompts
          generated-source-repair-prompt
          generated-source-apply)
  (import (scheme base)
          (scheme read))
  (begin
    ;; Sentinel for option and record lookups where a present #f is meaningful.
    (define generated-source-missing-field (list
      'generated-source-missing-field))

    (define (generated-source-record-field record field)
      "Return FIELD's tagged field record from RECORD, or #f when absent."
      (let ((fields
             (cond
              ((and (pair? record) (symbol? (car record))) (cdr record))
              ((list? record) record)
              (else '()))))
        (let loop ((rest fields))
          (cond
           ((null? rest) #f)
           ((and (pair? (car rest))
                 (eq? (car (car rest)) field))
            (car rest))
           (else (loop (cdr rest)))))))

    (define (generated-source-record-field-value record field default)
      "Return FIELD's value from tagged-list RECORD, or DEFAULT when absent."
      #((parameters
         (record (type list)
          (description "Tagged record or association list to inspect."))
         (field (type symbol)
          (description "Field name to read."))
         (default . "Fallback returned when FIELD is absent."))
        (returns . "The field value or DEFAULT.")
        (effects pure))
      (let ((entry (generated-source-record-field record field)))
        (if (and entry (pair? (cdr entry)))
            (car (cdr entry))
            default)))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT when absent."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (tagged? datum tag)
      "Return #t when DATUM is a tagged list headed by TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (generated-source-diagnostic stage reason message . fields)
      "Return one Scheme-readable generated-source diagnostic."
      #((parameters
         (stage (type symbol)
          (description "Loop stage that produced the diagnostic."))
         (reason (type symbol)
          (description "Stable machine-readable reason symbol."))
         (message (type string)
          (description "Human-readable diagnostic summary."))
         (fields (type list)
          (description "Additional `(field value)' diagnostic fields.")))
        (returns (type generated-source-diagnostic)
         (description "Tagged diagnostic datum."))
        (effects allocation))
      (append
       (list 'generated-source-diagnostic
             (list 'stage stage)
             (list 'reason reason)
             (list 'message message))
       fields))

    (define (condition-message condition)
      "Return a stable message string for CONDITION."
      (cond
       ((error-object? condition) (error-object-message condition))
       (else "reader signaled a condition")))

    (define (whitespace? char)
      "Return #t when CHAR is ASCII whitespace."
      (or (char=? char #\space)
          (char=? char #\tab)
          (char=? char #\newline)
          (char=? char #\return)))

    (define (ascii-digit? char)
      "Return #t when CHAR is an ASCII decimal digit."
      (and (char>=? char #\0)
           (char<=? char #\9)))

    (define (blank-string? text)
      "Return #t when TEXT has only whitespace."
      (let ((length (string-length text)))
        (let loop ((index 0))
          (or (= index length)
              (and (whitespace? (string-ref text index))
                   (loop (+ index 1)))))))

    (define (trim-left-index text)
      "Return the first non-whitespace index in TEXT."
      (let ((length (string-length text)))
        (let loop ((index 0))
          (if (and (< index length)
                   (whitespace? (string-ref text index)))
              (loop (+ index 1))
              index))))

    (define (trim-right-index text)
      "Return the exclusive right edge after trimming whitespace from TEXT."
      (let loop ((index (string-length text)))
        (if (and (> index 0)
                 (whitespace? (string-ref text (- index 1))))
            (loop (- index 1))
            index)))

    (define (trim-string text)
      "Return TEXT with surrounding ASCII whitespace removed."
      (let ((left (trim-left-index text))
            (right (trim-right-index text)))
        (if (> left right)
            ""
            (substring text left right))))

    (define (string-prefix-at? text prefix index)
      "Return #t when TEXT has PREFIX at INDEX."
      (let ((text-length (string-length text))
            (prefix-length (string-length prefix)))
        (and (<= (+ index prefix-length) text-length)
             (let loop ((offset 0))
               (or (= offset prefix-length)
                   (and (char=? (string-ref text (+ index offset))
                                (string-ref prefix offset))
                        (loop (+ offset 1))))))))

    (define (find-substring text needle start)
      "Return NEEDLE's first index in TEXT at or after START, or #f."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index start))
          (cond
           ((> (+ index needle-length) text-length) #f)
           ((string-prefix-at? text needle index) index)
           (else (loop (+ index 1)))))))

    (define (count-substrings text needle)
      "Return the number of non-overlapping NEEDLE occurrences in TEXT."
      (let ((needle-length (string-length needle)))
        (let loop ((start 0) (count 0))
          (let ((index (find-substring text needle start)))
            (if index
                (loop (+ index needle-length) (+ count 1))
                count)))))

    (define (find-newline text start)
      "Return the next newline index in TEXT at or after START, or #f."
      (let ((length (string-length text)))
        (let loop ((index start))
          (cond
           ((= index length) #f)
           ((char=? (string-ref text index) #\newline) index)
           (else (loop (+ index 1)))))))

    (define (supported-fence-language? language)
      "Return #t when LANGUAGE names a Scheme Markdown fence."
      (or (string=? language "scheme")
          (string=? language "r7rs")
          (string=? language "r7rs-scheme")))

    (define (source-start-char text)
      "Return the first significant source character, skipping line comments."
      (let ((length (string-length text)))
        (let loop ((index 0))
          (cond
           ((= index length) #f)
           ((whitespace? (string-ref text index))
            (loop (+ index 1)))
           ((char=? (string-ref text index) #\;)
            (let ((newline (find-newline text index)))
              (if newline
                  (loop (+ newline 1))
                  #f)))
           (else (string-ref text index))))))

    (define (scheme-source-start? char)
      "Return #t when CHAR is a conservative Scheme source starter."
      (and char
           (or (char=? char #\()
               (char=? char #\')
               (char=? char #\`)
               (char=? char #\,)
               (char=? char #\#)
               (char=? char #\")
               (char=? char #\+)
               (char=? char #\-)
               (ascii-digit? char))))

    (define (normalization-result status kind source diagnostics)
      "Return an internal normalization result."
      (list 'normalization
            (list 'status status)
            (list 'kind kind)
            (list 'source source)
            (list 'diagnostics diagnostics)))

    (define (normalization-rejected reason message . fields)
      "Return an internal rejected normalization result."
      (normalization-result
       'rejected
       'rejected
       #f
       (list
        (apply generated-source-diagnostic
               'normalize
               reason
               message
               fields))))

    (define (normalize-markdown-source text)
      "Return normalized source from a single complete Scheme Markdown fence."
      (let* ((trimmed (trim-string text))
             (fence-count (count-substrings trimmed "```")))
        (cond
         ((> fence-count 2)
          (normalization-rejected
           'ambiguous-markdown-fences
           "generated output contains multiple Markdown fences"))
         ((< fence-count 2)
          (normalization-rejected
           'partial-markdown-fence
           "generated output contains an incomplete Markdown fence"))
         ((not (string-prefix-at? trimmed "```" 0))
          (normalization-rejected
           'mixed-markdown-output
           "generated output mixes prose with a Markdown fence"))
         (else
          (let ((opening-end (find-newline trimmed 0)))
            (if (not opening-end)
                (normalization-rejected
                 'partial-markdown-fence
                 "generated output has no fenced source body")
                (let* ((language
                        (trim-string (substring trimmed 3 opening-end)))
                       (code-start (+ opening-end 1))
                       (closing-newline
                        (find-substring trimmed "\n```" code-start)))
                  (cond
                   ((not (supported-fence-language? language))
                    (normalization-rejected
                     'non-scheme-markdown-fence
                     "Markdown fence language is not Scheme"
                     (list 'language language)))
                   ((not closing-newline)
                    (normalization-rejected
                     'partial-markdown-fence
                     "generated output lacks a closing Markdown fence"))
                   (else
                    (let* ((closing-start (+ closing-newline 1))
                           (closing-end
                            (or (find-newline trimmed closing-start)
                                (string-length trimmed)))
                           (closing-line
                            (substring trimmed closing-start closing-end))
                           (trailer
                            (substring trimmed
                                       closing-end
                                       (string-length trimmed))))
                      (cond
                       ((not (string=? (trim-string closing-line) "```"))
                        (normalization-rejected
                         'mixed-markdown-output
                         "closing Markdown fence contains extra text"))
                       ((not (blank-string? trailer))
                        (normalization-rejected
                         'mixed-markdown-output
                         "generated output has prose after the Markdown \
fence"))
                       (else
                        (normalization-result
                         'ok
                         'markdown-fence
                         (substring trimmed code-start (+ closing-newline 1))
                         '())))))))))))))

    (define (normalize-plain-source text)
      "Return normalized source for plain Scheme text."
      (let ((first (source-start-char text)))
        (cond
         ((not first)
          (normalization-rejected
           'empty-output
           "generated output is empty"))
         ((not (scheme-source-start? first))
          (normalization-rejected
           'prose-output
           "plain generated output does not start like Scheme source"))
         (else
          (normalization-result 'ok 'plain text '())))))

    (define (normalize-generated-source text)
      "Return an internal normalization result for TEXT."
      (if (> (count-substrings text "```") 0)
          (normalize-markdown-source text)
          (normalize-plain-source text)))

    (define (read-source-forms source)
      "Read all datums from SOURCE, returning `(ok forms)' or `(error \
diagnostic)'."
      (guard (condition
              (else
               (list 'error
                     (generated-source-diagnostic
                      'read
                      'reader-error
                      (condition-message condition)
                      (list 'condition
                            (if (error-object? condition)
                                (list 'error-object
                                      (list 'message
                                            (error-object-message condition))
                                      (list 'irritants
                                            (error-object-irritants condition)
                    ))
                                condition))))))
        (let ((port (open-input-string source)))
          (let loop ((forms '()))
            (let ((form (read port)))
              (if (eof-object? form)
                  (list 'ok (reverse forms))
                  (loop (cons form forms))))))))

    (define (make-candidate status kind original source forms diagnostics)
      "Return a generated-source-candidate record."
      (list 'generated-source-candidate
            (list 'status status)
            (list 'kind kind)
            (list 'original original)
            (list 'source source)
            (list 'forms forms)
            (list 'diagnostics diagnostics)))

    (define (generated-source-candidate text)
      "Normalize TEXT into a generated-source candidate."
      #((parameters
         (text (type string)
          (description
           ("Untrusted model text. Accepted shapes are plain Scheme"
             "source or exactly one complete Scheme Markdown fence."))))
        (returns (type generated-source-candidate)
         (description
          ("Candidate preserving original text, normalized source,"
            "parsed forms or reader diagnostics, and status.")))
        (effects allocation port-read))
      (if (not (string? text))
          (error "generated-source-candidate expected a string" text))
      (let* ((normalization (normalize-generated-source text))
             (status
              (generated-source-record-field-value
               normalization 'status 'rejected))
             (kind
              (generated-source-record-field-value
               normalization 'kind 'rejected))
             (source
              (generated-source-record-field-value
               normalization 'source #f))
             (diagnostics
              (generated-source-record-field-value
               normalization 'diagnostics '())))
        (if (not (eq? status 'ok))
            (make-candidate 'rejected kind text source '() diagnostics)
            (let ((read-result (read-source-forms source)))
              (if (eq? (car read-result) 'ok)
                  (make-candidate 'ready kind text source (cadr read-result) '
                    ())
                  (make-candidate
                   'read-error
                   kind
                   text
                   source
                   '()
                   (list (cadr read-result))))))))

    (define (generated-source-candidate? datum)
      "Return #t when DATUM is a generated-source candidate."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description "#t for a `generated-source-candidate' datum."))
        (effects pure))
      (tagged? datum 'generated-source-candidate))

    (define (generated-source-candidate-status candidate)
      "Return CANDIDATE's status."
      #((parameters
         (candidate (type generated-source-candidate)
          (description "Candidate datum to inspect.")))
        (returns (type symbol)
         (description "`ready', `rejected', or `read-error'."))
        (effects pure))
      (generated-source-record-field-value candidate 'status 'rejected))

    (define (generated-source-candidate-source candidate)
      "Return CANDIDATE's normalized source text, or #f."
      #((parameters
         (candidate (type generated-source-candidate)
          (description "Candidate datum to inspect.")))
        (returns (type (or string boolean))
         (description "Normalized Scheme source text, or #f on rejection."))
        (effects pure))
      (generated-source-record-field-value candidate 'source #f))

    (define (generated-source-candidate-original candidate)
      "Return CANDIDATE's original untrusted text."
      #((parameters
         (candidate (type generated-source-candidate)
          (description "Candidate datum to inspect.")))
        (returns (type string)
         (description "Original model text used to build CANDIDATE."))
        (effects pure))
      (generated-source-record-field-value candidate 'original ""))

    (define (generated-source-candidate-forms candidate)
      "Return CANDIDATE's parsed forms."
      #((parameters
         (candidate (type generated-source-candidate)
          (description "Candidate datum to inspect.")))
        (returns (type list)
         (description "Parsed Scheme forms, or the empty list on failure."))
        (effects pure))
      (generated-source-record-field-value candidate 'forms '()))

    (define (generated-source-candidate-diagnostics candidate)
      "Return CANDIDATE's normalization or reader diagnostics."
      #((parameters
         (candidate (type generated-source-candidate)
          (description "Candidate datum to inspect.")))
        (returns (type list)
         (description "List of `generated-source-diagnostic' datums."))
        (effects pure))
      (generated-source-record-field-value candidate 'diagnostics '()))

    (define (generated-source-attempt? datum)
      "Return #t when DATUM is a generated-source attempt."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description "#t for a `generated-source-attempt' datum."))
        (effects pure))
      (tagged? datum 'generated-source-attempt))

    (define (make-attempt index candidate evaluation diagnostics)
      "Return a generated-source-attempt record."
      (list 'generated-source-attempt
            (list 'index index)
            (list 'candidate candidate)
            (list 'evaluation evaluation)
            (list 'diagnostics diagnostics)))

    (define (evaluation-status evaluation)
      "Return EVALUATION's status, or error."
      (generated-source-record-field-value evaluation 'status 'error))

    (define (evaluation-error-field evaluation)
      "Return EVALUATION's error field."
      (let ((entry (generated-source-record-field evaluation 'error)))
        (cond
         ((not entry) '())
         ((and (pair? (cdr entry)) (null? (cddr entry)))
          (car (cdr entry)))
         (else entry))))

    (define (evaluation-condition evaluation)
      "Return EVALUATION's debugger condition datum."
      (let ((error-field (evaluation-error-field evaluation)))
        (cond
         ((and (tagged? error-field 'condition)
               (pair? (cdr error-field))
               (tagged? (car (cdr error-field)) 'condition))
          (car (cdr error-field)))
         ((tagged? error-field 'condition) error-field)
         (else
          (generated-source-record-field-value
           error-field
           'condition
           '())))))

    (define (evaluation-message evaluation)
      "Return EVALUATION's error message."
      (generated-source-record-field-value
       (evaluation-error-field evaluation)
       'message
       "sandbox evaluation failed"))

    (define (condition-type condition)
      "Return CONDITION's type field."
      (generated-source-record-field-value condition 'type #f))

    (define (condition-symbol condition)
      "Return CONDITION's symbol field."
      (generated-source-record-field-value condition 'symbol #f))

    (define (evaluation-bindings evaluation)
      "Return binding names exposed by EVALUATION."
      (let ((bindings
             (generated-source-record-field-value
              evaluation
              'bindings
              generated-source-missing-field)))
        (if (not (eq? bindings generated-source-missing-field))
            bindings
            (let ((defined
                   (generated-source-record-field-value
                    evaluation
                    'defined-bindings
                    generated-source-missing-field)))
              (if (not (eq? defined generated-source-missing-field))
                  defined
                  (generated-source-record-field-value
                   evaluation 'exports '()))))))

    (define (member-equal? value list)
      "Return #t when LIST contains VALUE under equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (candidate-imports candidate)
      "Return import specs found in CANDIDATE's forms."
      (let loop ((forms (generated-source-candidate-forms candidate))
                 (imports '()))
        (cond
         ((null? forms) (reverse imports))
         ((and (pair? (car forms)) (eq? (car (car forms)) 'import))
          (loop (cdr forms) (append (reverse (cdr (car forms))) imports)))
         (else (loop (cdr forms) imports)))))

    (define (missing-import-diagnostics candidate required-imports)
      "Return diagnostics for REQUIRED-IMPORTS missing from CANDIDATE."
      (let ((actual (candidate-imports candidate)))
        (let loop ((required required-imports) (diagnostics '()))
          (cond
           ((null? required) (reverse diagnostics))
           ((member-equal? (car required) actual)
            (loop (cdr required) diagnostics))
           (else
            (loop
             (cdr required)
             (cons
              (generated-source-diagnostic
               'contract
               'missing-import
               "candidate did not import a required library"
               (list 'import (car required)))
              diagnostics)))))))

    (define (missing-binding-diagnostics evaluation required-bindings)
      "Return diagnostics for REQUIRED-BINDINGS absent from EVALUATION."
      (let ((actual (evaluation-bindings evaluation)))
        (let loop ((required required-bindings) (diagnostics '()))
          (cond
           ((null? required) (reverse diagnostics))
           ((member-equal? (car required) actual)
            (loop (cdr required) diagnostics))
           (else
            (loop
             (cdr required)
             (cons
              (generated-source-diagnostic
               'contract
               'missing-binding
               "sandbox evaluation did not expose a required binding"
               (list 'binding (car required)))
              diagnostics)))))))

    (define (diagnostic? datum)
      "Return #t when DATUM is a generated-source diagnostic."
      (tagged? datum 'generated-source-diagnostic))

    (define (diagnostic-list? value)
      "Return #t when VALUE is a list of generated-source diagnostics."
      (or (null? value)
          (and (pair? value)
               (diagnostic? (car value))
               (diagnostic-list? (cdr value)))))

    (define (post-check-diagnostics candidate evaluation post-check)
      "Return diagnostics from POST-CHECK over CANDIDATE and EVALUATION."
      (if (not post-check)
          '()
          (let ((result (post-check candidate evaluation)))
            (cond
             ((eq? result #t) '())
             ((diagnostic? result) (list result))
             ((diagnostic-list? result) result)
             (else
              (list
               (generated-source-diagnostic
                'contract
                'post-check-failed
                "post-evaluation generated-source check failed")))))))

    (define (evaluation-diagnostics evaluation)
      "Return diagnostics for a sandbox EVALUATION result."
      (let ((status (evaluation-status evaluation)))
        (cond
         ((or (eq? status 'ok) (eq? status 'values)) '())
         ((eq? (condition-type (evaluation-condition evaluation))
               'unbound-variable)
          (list
           (generated-source-diagnostic
            'eval
            'unbound-variable
            (evaluation-message evaluation)
            (list 'binding (condition-symbol (evaluation-condition evaluation)
              ))
            (list 'condition (evaluation-condition evaluation)))))
         (else
          (list
           (generated-source-diagnostic
            'eval
            'evaluation-error
            (evaluation-message evaluation)
            (list 'condition (evaluation-condition evaluation))))))))

    (define (contract-diagnostics candidate evaluation options)
      "Return contract diagnostics for CANDIDATE and EVALUATION under OPTIONS."
      (append
       (missing-import-diagnostics
        candidate
        (option-ref options 'required-imports '()))
       (missing-binding-diagnostics
        evaluation
        (option-ref options 'required-bindings '()))
       (post-check-diagnostics
        candidate
        evaluation
        (option-ref options 'post-check #f))))

    (define (attempt-diagnostics candidate evaluation options)
      "Return all diagnostics for CANDIDATE and EVALUATION."
      (if (not (eq? (generated-source-candidate-status candidate) 'ready))
          (generated-source-candidate-diagnostics candidate)
          (let ((eval-diagnostics (evaluation-diagnostics evaluation)))
            (if (null? eval-diagnostics)
                (contract-diagnostics candidate evaluation options)
                eval-diagnostics))))

    (define (make-run status attempts candidate diagnostics repair-prompts)
      "Return a generated-source-run record."
      (list 'generated-source-run
            (list 'status status)
            (list 'attempts attempts)
            (list 'candidate candidate)
            (list 'diagnostics diagnostics)
            (list 'repair-prompts repair-prompts)))

    (define (diagnostic-reasons diagnostics)
      "Return reason symbols from DIAGNOSTICS."
      (map (lambda (diagnostic)
             (generated-source-record-field-value diagnostic 'reason #f))
           diagnostics))

    (define (diagnostic-messages diagnostics)
      "Return messages from DIAGNOSTICS."
      (map (lambda (diagnostic)
             (generated-source-record-field-value diagnostic 'message ""))
           diagnostics))

    (define (generated-source-repair-prompt attempt)
      "Return a Scheme-readable repair request for ATTEMPT."
      #((parameters
         (attempt (type generated-source-attempt)
          (description "Failed generated-source attempt to repair.")))
        (returns (type generated-source-repair-request)
         (description
          ("Repair request carrying attempt index, normalized source,"
            "diagnostic reasons, messages, and full diagnostics.")))
        (effects allocation))
      (let* ((candidate
              (generated-source-record-field-value attempt 'candidate #f))
             (diagnostics
              (generated-source-record-field-value attempt 'diagnostics '())))
        (list 'generated-source-repair-request
              (list 'attempt
                    (generated-source-record-field-value attempt 'index 0))
              (list 'source
                    (and candidate
                         (generated-source-candidate-source candidate)))
              (list 'diagnostic-reasons
                    (diagnostic-reasons diagnostics))
              (list 'messages (diagnostic-messages diagnostics))
              (list 'diagnostics diagnostics))))

    (define (generated-source-run text options)
      "Run a bounded generated-source candidate workflow over TEXT."
      #((parameters
         (text (type string)
          (description "Initial generated source text to normalize and test.")
            )
         (options (type list)
          (description
           ("Association list. `evaluate' is a sandbox evaluator"
             "procedure receiving a candidate and returning an"
             "`evaluation-result' datum. Optional keys include"
             "`required-bindings', `required-imports', `post-check',"
             "`repair', and `max-retries'."))))
        (returns (type generated-source-run)
         (description
          ("Run record containing every attempt, repair prompt,"
            "accepted candidate if any, and final diagnostics.")))
        (effects allocation procedure-call))
      (let ((evaluate (option-ref options 'evaluate #f))
            (repair (option-ref options 'repair #f))
            (max-retries (option-ref options 'max-retries 0)))
        (let loop ((source text)
                   (attempt-index 1)
                   (remaining-retries max-retries)
                   (attempts '())
                   (repair-prompts '()))
          (let* ((candidate (generated-source-candidate source))
                 (evaluation
                  (if (and (eq? (generated-source-candidate-status candidate)
                                'ready)
                           evaluate)
                      (evaluate candidate)
                      'none))
                 (diagnostics
                  (if (and (eq? (generated-source-candidate-status candidate)
                                'ready)
                           (not evaluate))
                      (list
                       (generated-source-diagnostic
                        'eval
                        'missing-evaluator
                        "no sandbox evaluator was supplied"))
                      (attempt-diagnostics candidate evaluation options)))
                 (attempt
                  (make-attempt attempt-index candidate evaluation diagnostics
                    ))
                 (all-attempts (cons attempt attempts)))
            (cond
             ((null? diagnostics)
              (make-run 'accepted
                        (reverse all-attempts)
                        candidate
                        '()
                        (reverse repair-prompts)))
             ((and repair (> remaining-retries 0))
              (let* ((repair-prompt (generated-source-repair-prompt attempt))
                     (next-source (repair attempt repair-prompt)))
                (if (string? next-source)
                    (loop next-source
                          (+ attempt-index 1)
                          (- remaining-retries 1)
                          all-attempts
                          (cons repair-prompt repair-prompts))
                    (make-run 'rejected
                              (reverse all-attempts)
                              #f
                              diagnostics
                              (reverse
                               (cons repair-prompt repair-prompts))))))
             (else
              (make-run 'rejected
                        (reverse all-attempts)
                        #f
                        diagnostics
                        (reverse repair-prompts))))))))

    (define (generated-source-run? datum)
      "Return #t when DATUM is a generated-source run record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description "#t for a `generated-source-run' datum."))
        (effects pure))
      (tagged? datum 'generated-source-run))

    (define (generated-source-run-status run)
      "Return RUN's final status."
      #((parameters
         (run (type generated-source-run)
          (description "Run record to inspect.")))
        (returns (type symbol)
         (description "`accepted' or `rejected'."))
        (effects pure))
      (generated-source-record-field-value run 'status 'rejected))

    (define (generated-source-run-attempts run)
      "Return RUN's attempts in chronological order."
      #((parameters
         (run (type generated-source-run)
          (description "Run record to inspect.")))
        (returns (type list)
         (description "List of `generated-source-attempt' datums."))
        (effects pure))
      (generated-source-record-field-value run 'attempts '()))

    (define (generated-source-run-candidate run)
      "Return RUN's accepted candidate, or #f."
      #((parameters
         (run (type generated-source-run)
          (description "Run record to inspect.")))
        (returns (type (or generated-source-candidate boolean))
         (description "Accepted candidate for successful runs, otherwise #f.")
           )
        (effects pure))
      (generated-source-record-field-value run 'candidate #f))

    (define (generated-source-run-diagnostics run)
      "Return RUN's final diagnostics."
      #((parameters
         (run (type generated-source-run)
          (description "Run record to inspect.")))
        (returns (type list)
         (description "Final diagnostic list for rejected runs."))
        (effects pure))
      (generated-source-record-field-value run 'diagnostics '()))

    (define (generated-source-run-repair-prompts run)
      "Return RUN's repair prompt records."
      #((parameters
         (run (type generated-source-run)
          (description "Run record to inspect.")))
        (returns (type list)
         (description "Generated repair request datums, in order."))
        (effects pure))
      (generated-source-record-field-value run 'repair-prompts '()))

    (define (generated-source-apply run applier)
      "Apply RUN's accepted candidate through APPLIER, or reject safely."
      #((parameters
         (run (type generated-source-run)
          (description "Generated-source run record to gate."))
         (applier (type procedure)
          (description
           ("Procedure that applies the accepted candidate to the live"
             "session after sandbox success."))))
        (returns (type generated-source-application)
         (description
          ("Application record. APPLIER is called only when RUN is"
            "`accepted' and has an accepted candidate.")))
        (effects procedure-call allocation))
      (let ((candidate (generated-source-run-candidate run)))
        (if (and (eq? (generated-source-run-status run) 'accepted)
                 candidate)
            (list 'generated-source-application
                  (list 'status 'applied)
                  (list 'candidate candidate)
                  (list 'result (applier candidate)))
            (list 'generated-source-application
                  (list 'status 'rejected)
                  (list 'reason 'not-accepted)
                  (list 'candidate #f)
                  (list 'result #f)))))))
