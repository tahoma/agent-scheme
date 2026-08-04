;;; Manifest-derived compiler-front-end module planning.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (consent compiler-plan)
  (export consent-compiler-plan
          consent-compiler-plan-roots
          consent-compiler-plan-units
          consent-compiler-plan-native-libraries
          consent-compiler-unit-name
          consent-compiler-unit-source
          consent-compiler-unit-dependencies)
  (import (scheme base)
          (consent compiler-manifest)
          (consent manifest)
          (stdlib manifest)
          (data manifest)
          (agent manifest)
          (cli manifest))
  (begin
    ;; Associate source-path prefixes with their collection manifests.
    (define compiler-plan-collection-manifests
      (list (cons "consent/" consent-library-manifest)
            (cons "stdlib/" stdlib-manifest)
            (cons "data/" data-library-manifest)
            (cons "agent/" agent-library-manifest)
            (cons "cli/" cli-library-manifest)))

    (define (compiler-record-field record name default)
      "Return NAME's value from tagged RECORD, or DEFAULT when absent."
      (let ((entry (and (pair? record) (assq name (cdr record)))))
        (if entry (cadr entry) default)))

    (define (compiler-source-path source)
      "Return the relative path in SOURCE metadata, or #f."
      (and (pair? source)
           (eq? (car source) 'path)
           (pair? (cdr source))
           (string? (cadr source))
           (cadr source)))

    (define (compiler-dependency-name dependency)
      "Return DEPENDENCY's canonical library name."
      (if (and (pair? dependency)
               (eq? (car dependency) 'library)
               (pair? (cdr dependency)))
          (cadr dependency)
          dependency))

    (define (compiler-entry-name entry)
      "Return manifest ENTRY's canonical library name."
      (compiler-record-field entry 'name #f))

    (define (compiler-entry-dependencies entry)
      "Return manifest ENTRY's normalized dependency library names."
      (map compiler-dependency-name
           (compiler-record-field entry 'dependencies '())))

    (define (compiler-entry-source root entry)
      "Return ROOT-relative source path for manifest ENTRY, or #f."
      (let ((path
             (compiler-source-path
              (compiler-record-field entry 'source #f))))
        (and path (string-append root path))))

    (define (compiler-find-entry name)
      "Return NAME's manifest root and entry, or #f when unknown."
      (let collection-loop ((collections compiler-plan-collection-manifests))
        (if (null? collections)
            #f
            (let entry-loop ((entries (cdar collections)))
              (cond
               ((null? entries) (collection-loop (cdr collections)))
               ((equal? name (compiler-entry-name (car entries)))
                (cons (caar collections) (car entries)))
               (else (entry-loop (cdr entries))))))))

    (define (compiler-name-member? name names)
      "Return #t when NAMES contains library NAME."
      (let loop ((rest names))
        (and (pair? rest)
             (or (equal? name (car rest)) (loop (cdr rest))))))

    (define (compiler-project-library-name? name)
      "Return #t when NAME belongs to a repository-owned collection."
      (and (pair? name)
           (memq (car name) '(consent stdlib data agent cli))))

    (define (compiler-external-library-name? name prefixes)
      "Return #t when NAME is supplied by one of target PREFIXES."
      (and (pair? name) (memq (car name) prefixes)))

    (define (compiler-unit name source dependencies)
      "Return one canonical compiler unit record."
      (list 'compiler-unit
            (list 'name name)
            (list 'source source)
            (list 'dependencies dependencies)))

    (define (compiler-generated-unit unit)
      "Normalize one compiler UNIT from image metadata."
      (compiler-unit
       (compiler-record-field unit 'name #f)
       (compiler-record-field unit 'source #f)
       (compiler-record-field unit 'dependencies '())))

    (define (consent-compiler-plan . maybe-image)
      "Resolve a compiler image into a deterministic dependency-ordered plan."
      #((parameters
         (maybe-image (type list)
          (description
           "Optional singleton compiler-image name; defaults to consent-runtim\
e.")))
        (returns (type list)
         (description "Canonical compiler-plan record."))
        (effects allocation error))
      (if (> (length maybe-image) 1)
          (error "consent-compiler-plan: too many image names"))
      (let* ((image-name
              (if (null? maybe-image) 'consent-runtime (car maybe-image)))
             (image (consent-compiler-image-ref image-name)))
        (if (not image)
            (error "consent-compiler-plan: unknown image" image-name))
        (let ((roots (compiler-record-field image 'roots '()))
              (image-units (compiler-record-field image 'units '()))
              (generated
               (compiler-record-field image 'generated-units '()))
              (external-prefixes
               (compiler-record-field image 'external-library-prefixes '()))
              (visited '())
              (ordered '()))
          (define (visit name active)
            (cond
             ((compiler-name-member? name visited) #t)
             ((compiler-name-member? name active)
              (error "consent-compiler-plan: dependency cycle" name active))
             ((compiler-external-library-name? name external-prefixes) #t)
             (else
              (let ((image-unit
                     (let loop ((rest image-units))
                       (and (pair? rest)
                            (if (equal?
                                 name
                                 (compiler-record-field
                                  (car rest) 'name #f))
                                (car rest)
                                (loop (cdr rest)))))))
                (if image-unit
                    (let ((normalized (compiler-generated-unit image-unit)))
                      (for-each
                       (lambda (dependency)
                         (visit dependency (cons name active)))
                       (consent-compiler-unit-dependencies normalized))
                      (set! visited (cons name visited))
                      (set! ordered (cons normalized ordered))
                      #t)
                    (let ((located (compiler-find-entry name)))
                      (if located
                          (let* ((entry (cdr located))
                                 (dependencies
                                  (compiler-entry-dependencies entry))
                                 (source
                                  (compiler-entry-source
                                   (car located) entry)))
                            (for-each
                             (lambda (dependency)
                               (visit dependency (cons name active)))
                             dependencies)
                            (set! visited (cons name visited))
                            (if source
                                (set! ordered
                                      (cons (compiler-unit
                                             name source dependencies)
                                            ordered)))
                            #t)
                          ;; Standard and host-provided libraries are leaves.
                          (if (compiler-project-library-name? name)
                              (error
                               "consent-compiler-plan: unknown project library\
"
                               name)
                              #t))))))))
          (for-each (lambda (root) (visit root '())) roots)
          (for-each
           (lambda (unit)
             (let ((normalized (compiler-generated-unit unit)))
               (for-each
                (lambda (dependency) (visit dependency '()))
                (consent-compiler-unit-dependencies normalized))
               (set! ordered (cons normalized ordered))))
           generated)
          (let ((units (reverse ordered))
                (native-libraries
                 (compiler-record-field image 'native-libraries '())))
            (for-each
             (lambda (name)
               (if (not (compiler-name-member? name visited))
                   (error
                    "consent-compiler-plan: native library is not reachable"
                    name)))
             native-libraries)
            (list 'compiler-plan
                  (list 'schema-version 1)
                  (list 'image image-name)
                  (list 'roots roots)
                  (list 'native-libraries native-libraries)
                  (list 'units units))))))

    (define (consent-compiler-plan-roots plan)
      "Return compiler image roots from PLAN."
      #((parameters
         (plan (type list) (description "Compiler-plan record.")))
        (returns (type list) (description "Canonical root library names."))
        (effects pure))
      (compiler-record-field plan 'roots '()))

    (define (consent-compiler-plan-units plan)
      "Return dependency-ordered units from compiler PLAN."
      #((parameters
         (plan (type list) (description "Compiler-plan record.")))
        (returns (type list) (description "Ordered compiler-unit records."))
        (effects pure))
      (compiler-record-field plan 'units '()))

    (define (consent-compiler-plan-native-libraries plan)
      "Return PLAN root libraries registered as native implementations."
      #((parameters
         (plan (type list) (description "Compiler-plan record.")))
        (returns (type list)
         (description "Canonical native-registration library names."))
        (effects pure))
      (compiler-record-field plan 'native-libraries '()))

    (define (consent-compiler-unit-name unit)
      "Return compiler UNIT's canonical library name."
      #((parameters
         (unit (type list) (description "Compiler-unit record.")))
        (returns (type list) (description "Canonical library name."))
        (effects pure))
      (compiler-record-field unit 'name #f))

    (define (consent-compiler-unit-source unit)
      "Return compiler UNIT's canonical source path."
      #((parameters
         (unit (type list) (description "Compiler-unit record.")))
        (returns (type string) (description
          "Repository-relative source path."))
        (effects pure))
      (compiler-record-field unit 'source #f))

    (define (consent-compiler-unit-dependencies unit)
      "Return compiler UNIT's direct library dependencies."
      #((parameters
         (unit (type list) (description "Compiler-unit record.")))
        (returns (type list) (description "Canonical dependency names."))
        (effects pure))
      (compiler-record-field unit 'dependencies '()))))
