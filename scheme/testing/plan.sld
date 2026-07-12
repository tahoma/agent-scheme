;;; Portable multi-program test plans.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (testing plan)
  (export testing-plan-read
          testing-plan-validate
          testing-plan?
          testing-plan-programs
          testing-plan-shards
          testing-plan-program-path
          testing-plan-program-tags
          testing-plan-shard-names
          testing-plan-selector
          testing-plan-select
          testing-plan-files)
  (import (scheme base)
          (scheme file)
          (scheme read))
  (begin
    (define (testing-plan-field record name)
      "Return RECORD field NAME, or false when it is absent."
      (let ((entry (and (pair? record) (assq name (cdr record)))))
        (and entry (pair? (cdr entry)) (cadr entry))))

    (define (testing-plan-record? datum tag)
      "Return true when DATUM is a record tagged by TAG."
      (and (pair? datum) (eq? (car datum) tag) (list? datum)))

    (define (testing-plan-every predicate values)
      "Return true when PREDICATE accepts every member of VALUES."
      (let loop ((rest values))
        (or (null? rest)
            (and (predicate (car rest)) (loop (cdr rest))))))

    (define (testing-plan-unique? values)
      "Return true when VALUES contains no duplicate objects."
      (let loop ((rest values) (seen '()))
        (or (null? rest)
            (and (not (member (car rest) seen))
                 (loop (cdr rest) (cons (car rest) seen))))))

    (define (testing-plan-path? path)
      "Return true when PATH is a shell-safe line-oriented file name."
      (and (string? path)
           (> (string-length path) 0)
           (let loop ((index 0))
             (or (= index (string-length path))
                 (and (not (char=? (string-ref path index) #\newline))
                      (not (char=? (string-ref path index) #\return))
                      (loop (+ index 1)))))))

    (define (testing-plan-program-path program)
      "Return PROGRAM's source path."
      #((parameters
         (program (type list) (description "Test-program record.")))
        (returns (type string) (description "Program source path."))
        (effects pure))
      (testing-plan-field program 'path))

    (define (testing-plan-program-tags program)
      "Return PROGRAM's selection and scheduling tags."
      #((parameters
         (program (type list) (description "Test-program record.")))
        (returns (type (list-of symbol)) (description "Program tags."))
        (effects pure))
      (testing-plan-field program 'tags))

    (define (testing-plan-program-valid? program)
      "Return true when PROGRAM has a valid portable plan shape."
      (let ((path (testing-plan-program-path program))
            (tags (testing-plan-program-tags program)))
        (and (testing-plan-record? program 'program)
             (testing-plan-path? path)
             (list? tags)
             (testing-plan-every symbol? tags)
             (testing-plan-unique? tags))))

    (define (testing-plan-selector-valid? datum)
      "Return true when DATUM is a supported program selector."
      (cond
       ((and (pair? datum) (eq? (car datum) 'all) (null? (cdr datum))) #t)
       ((and (pair? datum) (eq? (car datum) 'path)
             (pair? (cdr datum)) (null? (cddr datum)))
        (testing-plan-path? (cadr datum)))
       ((and (pair? datum) (eq? (car datum) 'tag)
             (pair? (cdr datum)) (null? (cddr datum)))
        (symbol? (cadr datum)))
       ((and (pair? datum) (memq (car datum) '(and or)))
        (testing-plan-every testing-plan-selector-valid? (cdr datum)))
       ((and (pair? datum) (eq? (car datum) 'not)
             (pair? (cdr datum)) (null? (cddr datum)))
        (testing-plan-selector-valid? (cadr datum)))
       (else #f)))

    (define (testing-plan-shard-valid? shard)
      "Return true when SHARD has a name and supported selector."
      (and (testing-plan-record? shard 'shard)
           (symbol? (testing-plan-field shard 'name))
           (testing-plan-selector-valid?
            (testing-plan-field shard 'selector))))

    (define (testing-plan-programs plan)
      "Return PLAN's ordered program records."
      #((parameters
         (plan (type list) (description "Scheme-readable test plan.")))
        (returns (type (list-of list)) (description "Program records."))
        (effects pure))
      (testing-plan-field plan 'programs))

    (define (testing-plan-shards plan)
      "Return PLAN's named shard records."
      #((parameters
         (plan (type list) (description "Scheme-readable test plan.")))
        (returns (type (list-of list)) (description "Shard records."))
        (effects pure))
      (testing-plan-field plan 'shards))

    (define (testing-plan-validate plan)
      "Validate and return PLAN, or raise an error describing its defect."
      #((parameters
         (plan (type list) (description "Scheme-readable test plan.")))
        (returns (type list) (description "The validated PLAN."))
        (effects error))
      (if (not (testing-plan-record? plan 'testing-plan))
          (error "test plan must be a testing-plan record" plan))
      (if (not (equal? (testing-plan-field plan 'version) 1))
          (error "unsupported test plan version"
                 (testing-plan-field plan 'version)))
      (let ((programs (testing-plan-programs plan))
            (shards (testing-plan-shards plan)))
        (if (not (and (list? programs) (pair? programs)))
            (error "test plan programs must be a non-empty list" programs))
        (if (not (testing-plan-every testing-plan-program-valid? programs))
            (error "invalid test plan program" programs))
        (if (not (testing-plan-unique?
                  (map testing-plan-program-path programs)))
            (error "duplicate test plan program path" programs))
        (if (not (and (list? shards) (pair? shards)))
            (error "test plan shards must be a non-empty list" shards))
        (if (not (testing-plan-every testing-plan-shard-valid? shards))
            (error "invalid test plan shard" shards))
        (if (not (testing-plan-unique?
                  (map (lambda (shard)
                         (testing-plan-field shard 'name))
                       shards)))
            (error "duplicate test plan shard name" shards)))
      plan)

    (define (testing-plan? datum)
      "Return true when DATUM is a valid portable test plan."
      #((parameters (datum . "Value to inspect."))
        (returns (type boolean) (description "Whether DATUM is a valid plan."))
        (effects pure))
      (guard (condition (else #f))
        (testing-plan-validate datum)
        #t))

    (define (testing-plan-read path)
      "Read and validate one Scheme test-plan datum from PATH."
      #((parameters
         (path (type string) (description "Test-plan datum file path.")))
        (returns (type list) (description "Validated test plan."))
        (effects file-read allocation error))
      (call-with-input-file path
        (lambda (port)
          (let* ((plan (read port))
                 (trailing (read port)))
            (if (eof-object? plan) (error "empty test plan" path))
            (if (not (eof-object? trailing))
                (error "test plan contains trailing data" path))
            (testing-plan-validate plan)))))

    (define (testing-plan-selector datum)
      "Compile selector DATUM into a test-program predicate."
      #((parameters (datum (type list) (description "Program selector.")))
        (returns (type procedure) (description "Program predicate."))
        (effects allocation error))
      (if (not (testing-plan-selector-valid? datum))
          (error "invalid test plan selector" datum))
      (cond
       ((eq? (car datum) 'all) (lambda (program) program #t))
       ((eq? (car datum) 'path)
        (lambda (program)
          (string=? (testing-plan-program-path program) (cadr datum))))
       ((eq? (car datum) 'tag)
        (lambda (program)
          (if (memq (cadr datum) (testing-plan-program-tags program)) #t #f)))
       ((eq? (car datum) 'and)
        (let ((selectors (map testing-plan-selector (cdr datum))))
          (lambda (program)
            (let loop ((rest selectors))
              (or (null? rest)
                  (and ((car rest) program) (loop (cdr rest))))))))
       ((eq? (car datum) 'or)
        (let ((selectors (map testing-plan-selector (cdr datum))))
          (lambda (program)
            (let loop ((rest selectors))
              (and (pair? rest)
                   (or ((car rest) program) (loop (cdr rest))))))))
       (else
        (let ((selector (testing-plan-selector (cadr datum))))
          (lambda (program) (not (selector program)))))))

    (define (testing-plan-shard-names plan)
      "Return PLAN's shard names in declaration order."
      #((parameters
         (plan (type list) (description "Scheme-readable test plan.")))
        (returns (type (list-of symbol)) (description "Shard names."))
        (effects error))
      (map (lambda (shard) (testing-plan-field shard 'name))
           (testing-plan-shards (testing-plan-validate plan))))

    (define (testing-plan-shard plan name)
      "Return PLAN shard NAME, or raise an error when it is unknown."
      (let loop ((rest (testing-plan-shards plan)))
        (cond
         ((null? rest) (error "unknown test plan shard" name))
         ((eq? (testing-plan-field (car rest) 'name) name) (car rest))
         (else (loop (cdr rest))))))

    (define (testing-plan-select plan shard-name)
      "Return PLAN programs selected by SHARD-NAME in declaration order."
      #((parameters
         (plan (type list) (description "Validated or raw test plan."))
         (shard-name (type symbol) (description "Named plan shard.")))
        (returns (type list) (description "Selected program records."))
        (effects allocation error))
      (testing-plan-validate plan)
      (let* ((shard (testing-plan-shard plan shard-name))
             (selector
              (testing-plan-selector
               (testing-plan-field shard 'selector)))
             (selected
              (let loop ((rest (testing-plan-programs plan)) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((selector (car rest))
                  (loop (cdr rest) (cons (car rest) result)))
                 (else (loop (cdr rest) result))))))
        (if (null? selected)
            (error "test plan shard selected no programs" shard-name))
        selected))

    (define (testing-plan-files plan shard-name)
      "Return source paths selected from PLAN by SHARD-NAME."
      #((parameters
         (plan (type list) (description "Scheme-readable test plan."))
         (shard-name (type symbol) (description "Named plan shard.")))
        (returns (type (list-of string)) (description "Selected paths."))
        (effects allocation error))
      (map testing-plan-program-path
           (testing-plan-select plan shard-name)))))
