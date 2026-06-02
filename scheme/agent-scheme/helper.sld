;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
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

    (define (agent-scheme-make-helper-store)
      "Construct an empty helper store."
      #((parameters . ())
        (returns . "A mutable helper store with no helpers, no artifacts, and the next generated id set to zero.")
        (effects . (allocation)))
      (make-helper-store '() '() 0))

    (define (copy-datum datum)
      "Return a copy of DATUM so public records do not share nested list cells."
      (cond
       ((pair? datum)
        (cons (copy-datum (car datum))
              (copy-datum (cdr datum))))
       ((vector? datum)
        (list->vector (map copy-datum (vector->list datum))))
       (else datum)))

    (define (member-equal? value list)
      "Report whether VALUE appears in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (let ((normalized (if (eq? scope 'project) 'project-private scope)))
        (if (member-equal? normalized agent-scheme-helper-scopes)
            normalized
            (error "unknown helper scope" scope))))

    (define (next-sequence! store)
      "Increment STORE's sequence and return the new value."
      (let ((next (+ (store-next-id store) 1)))
        (set-store-next-id! store next)
        next))

    (define (integer-datum sequence)
      "Return SEQUENCE as an Agent Scheme exact integer datum."
      (agent-scheme-make-canonical-integer sequence))

    (define (field-value record field)
      "Return FIELD from RECORD or #f."
      (let loop ((fields (cdr record)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (eq? (caar fields) field))
          (cadr (car fields)))
         (else (loop (cdr fields))))))

    (define (helper-record-name record)
      "Return RECORD's helper library name."
      #((parameters . ((record . "Helper record datum.")))
        (returns . "The helper library name field.")
        (effects . (pure)))
      (field-value record 'name))

    (define (helper-record-forms record)
      "Return RECORD's helper source forms."
      #((parameters . ((record . "Helper record datum.")))
        (returns . "The helper source forms field.")
        (effects . (pure)))
      (field-value record 'forms))

    (define (library-name? datum)
      "Return #t when DATUM is a valid helper library name."
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

    (define (normalize-library-name library-name)
      "Validate and return helper LIBRARY-NAME."
      (if (library-name? library-name)
          library-name
          (error "invalid helper library name" library-name)))

    (define (scope-helpers store scope)
      "Return helper records from STORE belonging to SCOPE, newest first."
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-helpers store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((eq? (field-value (car records) 'scope) normalized-scope)
            (loop (cdr records) (cons (car records) result)))
           (else (loop (cdr records) result))))))

    (define (without-helper store scope name)
      "Return STORE helper records with NAME removed from SCOPE."
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-helpers store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((and (eq? (field-value (car records) 'scope) normalized-scope)
                 (equal? (helper-record-name (car records)) name))
            (loop (cdr records) result))
           (else (loop (cdr records) (cons (car records) result)))))))

    (define (helper-ref store scope library-name)
      "Return a helper record from STORE by SCOPE and LIBRARY-NAME, or #f."
      #((parameters . ((store . "Helper store to search.")
                       (scope . "Helper scope symbol.")
                       (library-name . "Scheme library name for the helper.")))
        (returns . "The matching helper record datum, or #f.")
        (effects . (state-read error)))
      (let ((name (normalize-library-name library-name)))
        (let loop ((records (scope-helpers store scope)))
          (cond
           ((null? records) #f)
           ((equal? (helper-record-name (car records)) name) (car records))
           (else (loop (cdr records)))))))

    (define (helper-list store scope)
      "Return helper records in SCOPE."
      #((parameters . ((store . "Helper store to inspect.")
                       (scope . "Helper scope symbol.")))
        (returns . "Helper record datums in SCOPE, newest first.")
        (effects . (state-read error)))
      (scope-helpers store scope))

    (define (make-helper-record store scope library-name forms source existing)
      "Build a canonical helper library record."
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

    (define (helper-save! store scope library-name forms source)
      "Store FORMS as helper LIBRARY-NAME in SCOPE and return its record."
      #((parameters . ((store . "Helper store to mutate.")
                       (scope . "Helper scope symbol.")
                       (library-name . "Scheme library name for the helper.")
                       (forms . "Helper source forms as Scheme-readable data.")
                       (source . "Source metadata describing where the helper came from.")))
        (returns . "The stored helper record datum.")
        (effects . (state-write error)))
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

    (define (without-artifact store scope name)
      "Return STORE artifact records with NAME removed from SCOPE."
      (let ((normalized-scope (normalize-scope scope)))
        (let loop ((records (store-artifacts store)) (result '()))
          (cond
           ((null? records) (reverse result))
           ((and (eq? (field-value (car records) 'scope) normalized-scope)
                 (equal? (field-value (car records) 'name) name))
            (loop (cdr records) result))
           (else (loop (cdr records) (cons (car records) result)))))))

    (define (make-artifact-record store scope name datum source existing)
      "Build a canonical helper artifact record."
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

    (define (artifact-save! store scope name datum source)
      "Store artifact NAME with DATUM in SCOPE and return its record."
      #((parameters . ((store . "Helper store to mutate.")
                       (scope . "Helper artifact scope symbol.")
                       (name . "Artifact name symbol or string.")
                       (datum . "Artifact payload as Scheme-readable data.")
                       (source . "Source metadata describing where the artifact came from.")))
        (returns . "The stored artifact record datum.")
        (effects . (state-write error)))
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

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT if absent."
      (let ((entry (assq key options)))
        (if entry
            (let ((value (cdr entry)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (candidate-name helper-record options)
      "Return a candidate name for HELPER-RECORD using OPTIONS."
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

    (define (candidate-resource-fields options)
      "Build optional skill candidate resource fields from OPTIONS."
      (let ((examples (option-ref options 'examples #f))
            (references (option-ref options 'references #f))
            (tests (option-ref options 'tests #f))
            (resources (option-ref options 'resources #f)))
        (append
         (if examples (list (list 'examples (copy-datum examples))) '())
         (if references (list (list 'references (copy-datum references))) '())
         (if tests (list (list 'tests (copy-datum tests))) '())
         (if resources (list (list 'resources (copy-datum resources))) '()))))

    (define (helper-promote-to-skill helper-record options)
      "Promote HELPER-RECORD into a native skill candidate datum."
      #((parameters . ((helper-record . "Helper record datum to promote.")
                       (options . "Association list overriding name, description, resources, tests, and tags.")))
        (returns . "An `agent-skill-candidate` datum derived from HELPER-RECORD.")
        (effects . (pure))
        (see-also . (helper-save! helper-record-name helper-record-forms)))
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
