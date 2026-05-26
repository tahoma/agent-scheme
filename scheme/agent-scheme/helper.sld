;;; Portable Agent Scheme helper artifact records.
;;;
;;; This library owns host-neutral helper libraries, artifacts, and skill
;;; candidate datums.  Host adapters own persistence, approval prompts, and
;;; tracked project file writes.

(define-library (agent-scheme helper)
  (export agent-scheme-helper-scopes
          agent-scheme-make-helper-store
          agent-scheme-helper-store?
          helper-save!
          helper-ref
          helper-list
          helper-record-name
          helper-record-forms
          artifact-save!
          helper-promote-to-skill)
  (import (scheme base)
          (agent-scheme reader))
  (begin
    ;; Public helper scopes mirror the Agent Scheme architecture boundary.
    (define agent-scheme-helper-scopes
      '(session project-private project-tracked))

    ;; Mutable portable helper store for host-neutral tests and interpreter
    ;; primitives.  Records remain canonical datums.
    (define-record-type <agent-scheme-helper-store>
      (make-helper-store helpers artifacts next-id)
      agent-scheme-helper-store?
      (helpers store-helpers set-store-helpers!)
      (artifacts store-artifacts set-store-artifacts!)
      (next-id store-next-id set-store-next-id!))

    ;; Construct an empty helper store.
    (define (agent-scheme-make-helper-store)
      (make-helper-store '() '() 0))

    ;; Return a copy of DATUM so public records do not share nested list cells.
    (define (copy-datum datum)
      (cond
       ((pair? datum)
        (cons (copy-datum (car datum))
              (copy-datum (cdr datum))))
       ((vector? datum)
        (list->vector (map copy-datum (vector->list datum))))
       (else datum)))

    ;; Report whether VALUE appears in LIST using equal?.
    (define (member-equal? value list)
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    ;; Validate and return SCOPE.
    (define (normalize-scope scope)
      (let ((normalized (if (eq? scope 'project) 'project-private scope)))
        (if (member-equal? normalized agent-scheme-helper-scopes)
            normalized
            (error "unknown helper scope" scope))))

    ;; Increment STORE's sequence and return the new value.
    (define (next-sequence! store)
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        next))

    ;; Return SEQUENCE as an Agent Scheme exact integer datum.
    (define (integer-datum sequence)
      (agent-scheme-make-canonical-integer sequence))

    ;; Return FIELD from RECORD or #f.
    (define (field-value record field)
      (let loop ((fields (cdr record)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) field))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    ;; Return RECORD's helper library name.
    (define (helper-record-name record)
      (field-value record 'name))

    ;; Return RECORD's helper source forms.
    (define (helper-record-forms record)
      (field-value record 'forms))

    ;; Return #t when DATUM is a valid helper library name.
    (define (library-name? datum)
      (and (pair? datum)
           (let loop ((parts datum))
             (cond
              ((null? parts) #t)
              ((and (pair? parts)
                    (or (symbol? (car parts))
                        (and (integer? (car parts))
                             (>= (car parts) 0))))
               (loop (cdr parts)))
              (else #f)))))

    ;; Validate and return helper LIBRARY-NAME.
    (define (normalize-library-name library-name)
      (if (library-name? library-name)
          library-name
          (error "invalid helper library name" library-name)))

    ;; Return helper records from STORE belonging to SCOPE, newest first.
    (define (scope-helpers store scope)
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-helpers store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((eq? (field-value (car records) 'scope) normalized-scope)
            (loop (cdr records) (cons (car records) result)))
           (else (loop (cdr records) result))))))

    ;; Return STORE helper records with NAME removed from SCOPE.
    (define (without-helper store scope name)
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-helpers store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((and (eq? (field-value (car records) 'scope) normalized-scope)
                 (equal? (helper-record-name (car records)) name))
            (loop (cdr records) result))
           (else (loop (cdr records) (cons (car records) result)))))))

    ;; Return a helper record from STORE by SCOPE and LIBRARY-NAME, or #f.
    (define (helper-ref store scope library-name)
      (let ((name (normalize-library-name library-name)))
        (let loop ((records (scope-helpers store scope)))
          (cond
           ((null? records) #f)
           ((equal? (helper-record-name (car records)) name) (car records))
           (else (loop (cdr records)))))))

    ;; Return helper records in SCOPE.
    (define (helper-list store scope)
      (scope-helpers store scope))

    ;; Build a canonical helper library record.
    (define (make-helper-record store scope library-name forms source existing)
      (let* ((sequence (next-sequence! store))
             (created-at (if existing
                             (field-value existing 'created-at)
                             (integer-datum sequence))))
        (list 'agent-helper-library
              (list 'name (copy-datum library-name))
              (list 'scope scope)
              (list 'forms (copy-datum forms))
              (list 'source (copy-datum source))
              (list 'created-at created-at)
              (list 'updated-at (integer-datum sequence)))))

    ;; Store FORMS as helper LIBRARY-NAME in SCOPE and return its record.
    (define (helper-save! store scope library-name forms source)
      (let* ((normalized-scope (normalize-scope scope))
             (name (normalize-library-name library-name))
             (existing (helper-ref store normalized-scope name))
             (record (make-helper-record store
                                         normalized-scope
                                         name
                                         forms
                                         source
                                         existing)))
        (set-store-helpers!
         store
         (cons record (without-helper store normalized-scope name)))
        record))

    ;; Return STORE artifact records with NAME removed from SCOPE.
    (define (without-artifact store scope name)
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-artifacts store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((and (eq? (field-value (car records) 'scope) normalized-scope)
                 (equal? (field-value (car records) 'name) name))
            (loop (cdr records) result))
           (else (loop (cdr records) (cons (car records) result)))))))

    ;; Build a canonical helper artifact record.
    (define (make-artifact-record store scope name datum source existing)
      (let* ((sequence (next-sequence! store))
             (created-at (if existing
                             (field-value existing 'created-at)
                             (integer-datum sequence))))
        (list 'agent-artifact
              (list 'name (copy-datum name))
              (list 'scope scope)
              (list 'value (copy-datum datum))
              (list 'source (copy-datum source))
              (list 'created-at created-at)
              (list 'updated-at (integer-datum sequence)))))

    ;; Store artifact NAME with DATUM in SCOPE and return its record.
    (define (artifact-save! store scope name datum source)
      (let* ((normalized-scope (normalize-scope scope))
             (existing #f)
             (record (make-artifact-record store
                                           normalized-scope
                                           name
                                           datum
                                           source
                                           existing)))
        (set-store-artifacts!
         store
         (cons record (without-artifact store normalized-scope name)))
        record))

    ;; Return KEY from OPTIONS, or DEFAULT if absent.
    (define (option-ref options key default)
      (let ((entry (assq key options)))
        (if entry
            (let ((value (cdr entry)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    ;; Return a candidate name for HELPER-RECORD using OPTIONS.
    (define (candidate-name helper-record options)
      (option-ref options
                  'name
                  (let loop ((parts (helper-record-name helper-record))
                             (result ""))
                    (cond
                     ((null? parts) result)
                     ((string=? result "")
                      (loop (cdr parts) (symbol->string (car parts))))
                     (else
                      (loop (cdr parts)
                            (string-append result "-"
                                           (symbol->string (car parts)))))))))

    ;; Build optional skill candidate resource fields from OPTIONS.
    (define (candidate-resource-fields options)
      (let ((examples (option-ref options 'examples #f))
            (references (option-ref options 'references #f))
            (tests (option-ref options 'tests #f))
            (resources (option-ref options 'resources #f)))
        (append
         (if examples (list (list 'examples (copy-datum examples))) '())
         (if references (list (list 'references (copy-datum references))) '())
         (if tests (list (list 'tests (copy-datum tests))) '())
         (if resources (list (list 'resources (copy-datum resources))) '()))))

    ;; Promote HELPER-RECORD into a native skill candidate datum.
    (define (helper-promote-to-skill helper-record options)
      (let ((name (candidate-name helper-record options))
            (library-name (helper-record-name helper-record)))
        (append
         (list 'agent-skill-candidate
               (list 'name name)
               (list 'status 'candidate)
               (list 'source-library (copy-datum library-name))
               (list 'helper-library (copy-datum helper-record)))
         (candidate-resource-fields options)
         (list
          (list 'skill-scm
                (list 'skill
                      (list 'name name)
                      (list 'helper-libraries
                            (list (copy-datum library-name)))))))))))
