;;; Portable Consent Scheme library resolver support.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns source-library discovery, import-set resolution, and
;;; define-library evaluation without importing the evaluator module.

(define-library (consent library)
  (export consent-standard-source-library-specs
          consent-stdlib-source-library-specs
          consent-data-source-library-specs
          consent-runtime-source-files
          consent-library-catalog-entries
          consent-library-catalog-entry
          consent-library-catalog-search
          consent-library-catalog-runtime-source-files
          consent-library-catalog-sources
          consent-library-catalog-diagnostics
          consent-library-catalog-add-manifest!
          consent-library-catalog-remove-manifest!
          consent-library-catalog-add-root!
          consent-library-catalog-remove-root!
          consent-library-catalog-refresh!
          consent-library-resolve-record
          consent-library-load-record
          consent-library-solve-dependencies
          consent-library-paths
          consent-library-conflicts
          consent-library-snapshot
          consent-srfi-library-name
          consent-srfi-library-aliases
          consent-vendored-srfi-entry
          consent-vendored-srfi-record
          consent-install-library-backend!
          consent-native-argument-value
          consent-runtime-datum->native-datum
          consent-call-native-library
          consent-apply-callable
          import-form?
          define-library-form?
          eval-import
          eval-define-library
          resolve-library
          library-available?
          library-name-key
          library-registry-ref
          library-registry-set!
          export-specs
          ensure-compatible-import-bindings
          path-policy-allows-file?
          path-directory
          read-file-string
          with-include-directory
          form-named?)
  (import (scheme base)
          (scheme char)
          (scheme file)
          (consent character)
          (consent datum)
          (consent identity-map)
          (consent reader)
          (consent symbol)
          (consent symbol-boundary)
          (consent runtime)
          (consent base))
  (begin
    ;; Preserve host operations for implementation identity and cache checks.
    (define host-eq? eq?)
    ;; Recognize host symbols in private library metadata.
    (define host-symbol? symbol?)
    ;; Read host symbol names in private library metadata.
    (define host-symbol->string symbol->string)
    ;; Construct host symbols only for private native dispatch.
    (define host-string->symbol string->symbol)
    ;; Search private host identity lists without mixed-symbol semantics.
    (define host-memq memq)

    ;; Library metadata crosses the bootstrap symbol boundary.
    (define library-symbol? consent-host-symbol?)
    ;; Read library names across the owned/bootstrap boundary.
    (define library-symbol-name consent-host-symbol-name)
    ;; Compare library names across the owned/bootstrap boundary.
    (define library-symbol-eq? consent-host-symbol-eq?)
    ;; Compare library datums across the owned/bootstrap boundary.
    (define library-datum-equal? consent-host-symbol-equal?)
    ;; Search library name lists across the owned/bootstrap boundary.
    (define library-memq consent-host-symbol-memq)
    ;; Look up library declarations across the owned/bootstrap boundary.
    (define library-assq consent-host-symbol-assq)
    ;; Search library datums across the owned/bootstrap boundary.
    (define library-member consent-host-symbol-member)


    ;; Backend hook resolving interpreter primitive implementations.
    (define (library-primitive-resolver name)
      "Resolve primitive implementation NAME through the installed backend."
      (eval-error "library primitive backend is not installed" name))
    ;; Backend hook for host-capability-denied primitive factories.
    (define (library-policy-denied-primitive description)
      "Return a denied primitive for DESCRIPTION through the backend."
      (eval-error "library policy backend is not installed" description))
    ;; Backend hook for evaluating library body forms.
    (define (library-trampoline sequence environment context)
      "Evaluate library body SEQUENCE through the installed backend."
      (eval-error "library trampoline backend is not installed"))
    ;; Backend hook for constructing syntax environments.
    (define (library-make-empty-syntax-environment parent)
      "Construct an empty syntax environment through the installed backend."
      (eval-error "library syntax environment backend is not installed"))
    ;; Backend hook for syntax-environment lookup.
    (define (library-syntax-environment-ref syntax-environment name)
      "Look up NAME in SYNTAX-ENVIRONMENT through the installed backend."
      (eval-error "library syntax lookup backend is not installed" name))
    ;; Backend hook for scoped syntax-environment evaluation.
    (define (library-with-syntax-environment context syntax-environment thunk)
      "Call THUNK with SYNTAX-ENVIRONMENT installed in CONTEXT."
      (eval-error "library syntax scope backend is not installed"))

    (define (consent-install-library-backend!
             primitive-resolver policy-denied trampoline
             make-empty-syntax-environment syntax-environment-ref
             with-syntax-environment)
      "Install interpreter and macro callbacks used by library resolution."
      #((parameters
         (primitive-resolver
          . ("Callback mapping a primitive identifier to its"
             "implementation."))
         (policy-denied (type procedure)
          (description
           ("Factory building a policy-denied primitive from a"
             "description.")))
         (trampoline (type procedure)
          (description
           ("Callback evaluating a library body sequence in an"
             "environment and context.")))
         (make-empty-syntax-environment (type procedure)
          (description
           ("Callback constructing a fresh syntax environment under a"
             "parent.")))
         (syntax-environment-ref (type procedure)
          (description "Callback looking up a name in a syntax environment."))
         (with-syntax-environment (type procedure)
          (description
           ("Callback running a thunk with a syntax environment"
             "installed in a context."))))
        (returns . ("The unspecified value after storing every backend hook."))
        (effects state-write))
      (set! library-primitive-resolver primitive-resolver)
      (set! library-policy-denied-primitive policy-denied)
      (set! library-trampoline trampoline)
      (set! library-make-empty-syntax-environment
        make-empty-syntax-environment)
      (set! library-syntax-environment-ref syntax-environment-ref)
      (set! library-with-syntax-environment with-syntax-environment)
      consent-unspecified)

    (define (library-primitive-implementation name)
      "Resolve a primitive implementation identifier through the backend."
      (library-primitive-resolver name))

    (define (library-primitive-spec name implementation minimum maximum)
      "Construct a primitive spec from a backend implementation identifier."
      (list name
            (library-primitive-implementation implementation)
            minimum
            maximum))

    ;; Alias specs are alists so new optional fields remain
    ;; backwards-compatible.
    (define (library-alias-field spec field)
      "Return FIELD from alias SPEC, or #f when absent."
      (let ((entry (library-assq field spec)))
        (if entry (cdr entry) #f)))

    ;; Cache selected source path and contents by manifest source-file/key
    ;; pair.
    (define manifest-source-library-source-cache '())

    ;; Canonical syntax is shared only in the process-wide default symbol
    ;; domain. Mutable literal realizations remain owned by evaluation
    ;; contexts, so the cached graph itself is never exposed for mutation.
    (define manifest-source-library-form-cache '())

    ;; Internal immutable-data libraries may keep one evaluated library object
    ;; in the process-wide default symbol domain. Their manifest realization
    ;; opts into sharing explicitly; ordinary source libraries remain isolated
    ;; because their exported state can be mutable.
    (define shared-immutable-source-library-cache '())

    ;; Bootstrap file name for every configured manifest root.
    (define library-manifest-index-file "manifest.sld")

    ;; Cache metadata read from configured collection manifests.
    (define library-collection-manifest-cache #f)

    ;; Trusted runtime source libraries may import private primitive backing
    ;; libraries while being loaded without making those libraries ordinary
    ;; user imports.
    (define source-library-internal-import-depth 0)

    ;; Cache manifest-backed catalog entries after the evaluator backend is
    ;; live.
    (define library-catalog-cache #f)

    ;; Ad-hoc manifest catalog sources are metadata only and have highest
    ;; precedence in discovery.
    (define library-catalog-ad-hoc-manifests '())

    ;; Manifest root catalog sources are metadata only and follow ad-hoc
    ;; inputs.
    (define library-catalog-root-manifests '())

    ;; Diagnostics emitted by the most recent catalog merge.
    (define library-catalog-diagnostics '())

    (define (proper-list-elements/maybe datum)
      "Return DATUM's list elements, or #f when DATUM is not a proper list."
      (let loop ((cursor datum) (elements '()))
        (cond
         ((null? cursor) (reverse elements))
         ((pair? cursor) (loop (cdr cursor) (cons (car cursor) elements)))
         (else #f))))

    (define (proper-library-name? datum)
      "Report whether DATUM is a proper R7RS library name."
      (and (pair? datum)
           (let ((parts (proper-list-elements/maybe datum)))
             (and parts
                  (let loop ((rest parts))
                    (cond
                     ((null? rest) #t)
                     ((or (library-symbol? (car rest))
                          (and (integer? (car rest))
                               (exact? (car rest))
                               (>= (car rest) 0))
                          (and (consent-number? (car rest))
                               (library-symbol-eq? (consent-number-kind (car
                              rest))
                                    'integer)
                               (library-symbol-eq? (consent-number-exactness
                              (car rest))
                                    'exact)
                               (>= (consent-number-value (car rest)) 0)))
                      (loop (cdr rest)))
                     (else #f)))))))

    (define (library-name-part-key part)
      "Return PART normalized for registry-key comparison."
      (if (consent-number? part)
          (consent-number-value part)
          part))

    (define (library-name-key name)
      "Validate and return NAME as a library registry key."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Candidate R7RS library name to validate.")))
        (returns (type (list-of (or symbol exact-integer)))
         (description "NAME unchanged when it is a proper library name."))
        (effects error))
      (if (proper-library-name? name)
          (map library-name-part-key name)
          (eval-error "invalid library name" name)))

    (define (assoc/equal key alist)
      "Search ALIST for KEY using equal? comparison."
      (cond
       ((null? alist) #f)
       ((library-datum-equal? key (caar alist)) (car alist))
       (else (assoc/equal key (cdr alist)))))

    (define (source-library-relative-path paths)
      "Return the canonical datadir/embedded-relative path for a source"
      "library: the last (most-relative) configured candidate."
      (if (null? (cdr paths))
          (car paths)
          (source-library-relative-path (cdr paths))))

    (define (consent-library-catalog-runtime-source-files)
      "Return runtime source files from the manifest-backed catalog seed."
      #((parameters)
        (returns (type list)
         (description
          ("A list of canonical relative source-file paths the runtime"
            "loads as data, derived from catalog source entries.")))
        (effects pure))
      (append
       (list (source-library-relative-path consent-base-prelude-load-paths)
             (source-library-relative-path consent-base-syntax-load-paths))
       (let loop ((entries (library-collection-manifest-entries))
                  (seen '())
                  (result '()))
         (cond
          ((null? entries) (reverse result))
          ((collection-entry-field (car entries) 'source-file #f)
           => (lambda (source-file)
                (if (library-member source-file seen)
                    (loop (cdr entries) seen result)
                    (loop (cdr entries)
                          (cons source-file seen)
                          (cons source-file result)))))
          (else (loop (cdr entries) seen result))))))

    (define (consent-runtime-source-files)
      "Return the canonical relative paths of every runtime-provided"
      "source file the interpreter loads as data."
      #((parameters)
        (returns (type list)
         (description
          ("A list of canonical relative source-file paths the runtime"
            "loads as data.")))
        (effects pure))
      (consent-library-catalog-runtime-source-files))

    (define (source-library-form key source description)
      "Return the single define-library form read from SOURCE for KEY."
      (let ((forms (consent-read-all
                    source
                    '((source-metadata . #f) (symbol-table . #f)))))
        (if (not (= (length forms) 1))
            (eval-error
             (string-append description " must contain exactly one form")
             key))
        (let* ((form (car forms))
               (parts (proper-list-elements
                       form
                       description)))
          (if (not (and (>= (length parts) 2)
                        (identifier-named? (car parts) 'define-library)
                        (library-datum-equal? (library-name-key (second parts))
                          key)))
              (eval-error
               (string-append description " name does not match registry key")
               key))
          form)))

    (define (library-root-file root relative)
      "Return ROOT-relative file path RELATIVE."
      (path-normalize (path-join root relative)))

    (define (library-read-file/maybe path)
      "Return PATH's text, or #f when it cannot be read."
      (guard (condition (else #f))
        (call-with-input-file path read-port-string)))

    (define (library-embedded-manifest-root-descriptor)
      "Return the embedded system manifest root descriptor, or #f."
      (let ((source (consent-embedded-source-ref library-manifest-index-file)))
        (and source
             (list
              (list 'root #f)
              (list 'root-id "embedded")
              (list 'root-kind 'system)
              (list 'manifest-source source)))))

    (define (library-manifest-root-descriptors)
      "Return configured manifest roots with readable top-level manifests."
      (let ((inputs
             (append
              (map (lambda (root) (list 'system root))
                   (consent-library-system-directory-list))
              (map (lambda (root) (list 'user root))
                   (consent-library-user-directory-list)))))
        (let loop ((rest inputs) (result '()))
          (if (null? rest)
              (let ((embedded (library-embedded-manifest-root-descriptor)))
                (if embedded
                    (append (reverse result) (list embedded))
                    (reverse result)))
              (let* ((root-kind (car (car rest)))
                     (root (path-normalize (cadr (car rest))))
                     (manifest-file
                      (library-root-file root library-manifest-index-file))
                     (source (library-read-file/maybe manifest-file)))
                (if source
                    (loop
                     (cdr rest)
                     (cons
                      (list
                       (list 'root root)
                       (list 'root-id root)
                       (list 'root-kind root-kind)
                       (list 'manifest-source source))
                      result))
                    (loop (cdr rest) result)))))))

    (define (library-default-manifest-root)
      "Return the first configured manifest root."
      (let ((roots (library-manifest-root-descriptors)))
        (if (pair? roots)
            (cadr (library-assq 'root (car roots)))
            (eval-error
             "no configured manifest root contains manifest.sld"
             library-manifest-index-file))))

    (define (collection-manifest-source-entry root relative description)
      "Return source entry for ROOT-relative manifest file RELATIVE."
      (let ((entry
             (if root
                 (let* ((path (library-root-file root relative))
                        (source (library-read-file/maybe path)))
                   (and source (cons path source)))
                 (let ((source (consent-embedded-source-ref relative)))
                   (and source (cons relative source))))))
        (if entry
            entry
            (eval-error
             (string-append description " source file is not readable")
             relative))))

    (define (manifest-quoted-value value variable key)
      "Return the quoted manifest data stored in VALUE."
      (let ((parts (proper-list-elements value "quoted manifest")))
        (if (not (and (= (length parts) 2)
                      (identifier-named? (car parts) 'quote)))
            (eval-error "manifest variable must be quoted" (list key
              variable)))
        (cadr parts)))

    (define (collection-manifest-define-value form variable key)
      "Return manifest data from DEFINE FORM for VARIABLE and KEY, or #f."
      (if (form-named? form 'define)
          (let ((parts
                 (proper-list-elements form "collection manifest define")))
            (if (and (= (length parts) 3)
                     (identifier-named? (cadr parts) variable))
                (manifest-quoted-value (car (cddr parts)) variable key)
                #f))
          #f))

    (define (manifest-library-quoted-variable source key variable description)
      "Return quoted VARIABLE from manifest library SOURCE."
      (let ((forms (consent-read-all
                    source
                    '((source-metadata . #f) (symbol-table . #f)))))
        (if (not (= (length forms) 1))
            (eval-error
             (string-append description " must contain exactly one form")
             key))
        (let* ((form (car forms))
               (parts (proper-list-elements form description)))
          (if (not (and (>= (length parts) 2)
                        (identifier-named? (car parts) 'define-library)
                        (library-datum-equal? (library-name-key (second parts))
                          key)))
              (eval-error
               (string-append description
                              " library name does not match registry key")
               key))
          (let outer ((declarations (cddr parts)))
            (cond
             ((null? declarations)
              (eval-error "manifest variable is not defined"
                          (list key variable)))
             ((form-named? (car declarations) 'begin)
              (let inner ((forms (cdr (proper-list-elements
                                       (car declarations)
                                       "collection manifest begin"))))
                (cond
                 ((null? forms) (outer (cdr declarations)))
                 ((collection-manifest-define-value (car forms) variable key)
                  => (lambda (value) value))
                 (else (inner (cdr forms))))))
             ((collection-manifest-define-value
               (car declarations) variable key)
              => (lambda (value) value))
             (else (outer (cdr declarations))))))))

    (define (library-manifest-index-value root-descriptor)
      "Return ROOT-DESCRIPTOR's quoted top-level manifest index."
      (manifest-library-quoted-variable
       (cadr (library-assq 'manifest-source root-descriptor))
       '(manifest index)
       'manifest-index
       "top-level manifest index"))

    (define (collection-manifest-fields entry description)
      "Return tagged manifest ENTRY fields, or raise DESCRIPTION."
      (let ((parts (proper-list-elements entry description)))
        (if (not (and (pair? parts)
                      (or (identifier-named? (car parts) 'manifest-entry)
                          (identifier-named? (car parts)
                                             'manifest-index-entry))))
            (eval-error
             (string-append
              description
              " must begin with manifest-entry or manifest-index-entry")
             entry))
        (cdr parts)))

    (define (collection-manifest-field entry field default)
      "Return FIELD from tagged manifest ENTRY, or DEFAULT."
      (let loop ((fields (collection-manifest-fields entry "manifest entry")))
        (cond
         ((null? fields) default)
         ((and (pair? (car fields))
               (let ((parts
                      (proper-list-elements (car fields) "manifest field")))
                 (and (pair? parts)
                      (identifier-named? (car parts) field)
                      parts)))
          => (lambda (parts)
               (if (null? (cdr parts)) default (cadr parts))))
         (else (loop (cdr fields))))))

    (define (collection-manifest-field-values entry field)
      "Return every value for FIELD from tagged manifest ENTRY."
      (let loop ((fields (collection-manifest-fields entry "manifest entry")))
        (cond
         ((null? fields) '())
         ((and (pair? (car fields))
               (let ((parts
                      (proper-list-elements (car fields) "manifest field")))
                 (and (pair? parts)
                      (identifier-named? (car parts) field)
                      parts)))
          => cdr)
         (else (loop (cdr fields))))))

    (define (collection-manifest-field-present? entry field)
      "Report whether tagged manifest ENTRY contains FIELD."
      (let loop ((fields (collection-manifest-fields entry "manifest entry")))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields))
               (let ((parts
                      (proper-list-elements (car fields) "manifest field")))
                 (and (pair? parts)
                      (identifier-named? (car parts) field))))
          #t)
         (else (loop (cdr fields))))))

    (define (collection-manifest-symbol value description)
      "Return VALUE when it is a symbol."
      (if (library-symbol? value)
          value
          (eval-error
           (string-append description " must be a symbol")
           value)))

    (define (collection-manifest-string value description)
      "Return VALUE when it is a string."
      (if (string? value)
          value
          (eval-error
           (string-append description " must be a string")
           value)))

    (define (collection-manifest-index-entry root-descriptor entry)
      "Return a collection manifest descriptor parsed from index ENTRY."
      (let* ((collection
              (collection-manifest-symbol
               (collection-manifest-field entry 'collection #f)
               "manifest index collection"))
             (root (cadr (library-assq 'root root-descriptor)))
             (root-id (cadr (library-assq 'root-id root-descriptor)))
             (root-kind (cadr (library-assq 'root-kind root-descriptor)))
             (key
              (library-name-key
               (collection-manifest-field entry 'manifest-library #f)))
             (variable
              (collection-manifest-symbol
               (collection-manifest-field entry 'manifest-variable #f)
               "manifest index variable"))
             (manifest-file
              (collection-manifest-string
               (collection-manifest-field entry 'manifest-file #f)
               "manifest index manifest-file"))
             (source-root
              (collection-manifest-string
               (collection-manifest-field entry 'source-root #f)
               "manifest index source-root"))
             (category
              (let ((value (collection-manifest-field entry 'category #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "manifest index category")
                    collection))))
        (list
         (list 'collection collection)
         (list 'key key)
         (list 'variable variable)
         (list 'manifest-file manifest-file)
         (list 'root root)
         (list 'root-kind root-kind)
         (list 'category category)
         (list 'source-root source-root)
         (list 'source-id
               (string-append root-id ":" (library-symbol-name collection))))))

    (define (collection-entry-field entry field default)
      "Return FIELD from collection ENTRY, or DEFAULT."
      (let ((cell (and entry (library-assq field entry))))
        (if cell (cadr cell) default)))

    (define (library-collection-manifest-specs)
      "Return collection manifest descriptors from configured manifest roots."
      (apply
       append
       (map
        (lambda (root-descriptor)
          (map
           (lambda (entry)
             (collection-manifest-index-entry root-descriptor entry))
           (proper-list-elements
            (library-manifest-index-value root-descriptor)
            "top-level manifest index entries")))
        (library-manifest-root-descriptors))))

    (define (library-manifest-root-cache-key)
      "Return cache key for configured manifest root lists."
      (list (consent-library-system-directory-list)
            (consent-library-user-directory-list)
            (consent-embedded-source-ref library-manifest-index-file)))

    (define (collection-manifest-source spec)
      "Return source text for collection manifest described by SPEC."
      (cdr (collection-manifest-source-entry
            (collection-entry-field spec 'root #f)
            (collection-entry-field spec 'manifest-file #f)
            "collection manifest")))

    (define (collection-manifest-library-value spec)
      "Return the quoted manifest data described by SPEC."
      (manifest-library-quoted-variable
       (collection-manifest-source spec)
       (collection-entry-field spec 'key #f)
       (collection-entry-field spec 'variable #f)
       "collection manifest library"))

    (define (collection-manifest-source-kind value)
      "Return VALUE normalized to the catalog source-kind vocabulary."
      (if (not value)
          #f
          (let ((kind
                 (collection-manifest-symbol
                  value
                  "collection manifest source-kind")))
            (cond
             ((library-symbol-eq? kind 'source-library) 'portable-source)
             ((library-symbol-eq? kind 'primitive-library) 'primitive)
             (else kind)))))

    (define (collection-manifest-library-list value description)
      "Return VALUE normalized as a list of library keys."
      (if value
          (map library-name-key (proper-list-elements value description))
          '()))

    (define (primitive-library-export-field entry field description)
      "Return FIELD from primitive export ENTRY."
      (let ((sentinel (list 'primitive-field-absent)))
        (let ((value
               (let loop ((fields (proper-list-elements entry description)))
                 (cond
                  ((null? fields) sentinel)
                  ((and (pair? (car fields))
                        (let ((parts
                               (proper-list-elements
                                (car fields)
                                description)))
                          (and (pair? parts)
                               (identifier-named? (car parts) field)
                               parts)))
                   => (lambda (parts)
                        (if (null? (cdr parts))
                            (eval-error
                             "primitive export field must have a value"
                             field))
                        (if (null? (cddr parts))
                            (cadr parts)
                            (cdr parts))))
                  (else (loop (cdr fields)))))))
          (if (library-symbol-eq? value sentinel)
              (eval-error "primitive export missing field" field)
              value))))

    (define (primitive-library-symbol-list value description)
      "Return VALUE as a list of symbols for primitive metadata."
      (let ((parts (proper-list-elements value description)))
        (for-each
         (lambda (part)
           (if (not (library-symbol? part))
               (eval-error
                (string-append description " entries must be symbols")
                part)))
         parts)
        parts))

    (define (primitive-library-arity value description)
      "Return primitive arity VALUE as (MINIMUM MAXIMUM)."
      (let ((parts (proper-list-elements value description)))
        (if (not (= (length parts) 2))
            (eval-error "primitive arity must have minimum and maximum"
                        value))
        (let ((minimum
               (manifest-nonnegative-integer
                (car parts)
                "primitive arity minimum"
                #f))
              (maximum
               (if (cadr parts)
                   (manifest-nonnegative-integer
                    (cadr parts)
                    "primitive arity maximum"
                    #f)
                   #f)))
          (if (not minimum)
              (eval-error "primitive arity minimum is required" value))
          (if (and maximum (> minimum maximum))
              (eval-error "primitive arity maximum is less than minimum"
                          value))
          (list minimum maximum))))

    (define (primitive-library-normalize-export entry description)
      "Return normalized primitive export metadata from ENTRY."
      (let ((name
             (primitive-library-export-field entry 'name description))
            (primitive
             (primitive-library-export-field entry 'primitive description))
            (arity
             (primitive-library-export-field entry 'arity description))
            (effects
             (primitive-library-export-field entry 'effects description))
            (capabilities
             (primitive-library-export-field
              entry
              'capabilities
              description)))
        (if (not (library-symbol? name))
            (eval-error "primitive export name must be a symbol" name))
        (if (not (library-symbol? primitive))
            (eval-error "primitive export implementation must be a symbol"
                        primitive))
        (list
         (list 'name name)
         (list 'primitive primitive)
         (list 'arity (primitive-library-arity arity description))
         (list 'effects
               (primitive-library-symbol-list effects description))
         (list 'capabilities
               (primitive-library-symbol-list capabilities description)))))

    (define (primitive-library-normalize-exports value description)
      "Return primitive export declarations from VALUE."
      (if value
          (map (lambda (entry)
                 (primitive-library-normalize-export entry description))
               (proper-list-elements value description))
          '()))

    ;; Manifest schema version recognized by load-light catalog readers.
    (define manifest-schema-version 1)

    (define (manifest-nonnegative-integer value description default)
      "Return VALUE as an exact non-negative integer, or DEFAULT when absent."
      (cond
       ((not value) default)
       ((and (integer? value) (exact? value) (>= value 0)) value)
       ((and (consent-number? value)
             (library-symbol-eq? (consent-number-kind value) 'integer)
             (library-symbol-eq? (consent-number-exactness value) 'exact)
             (>= (consent-number-value value) 0))
        (consent-number-value value))
       (else
        (eval-error
         (string-append description
                        " must be an exact non-negative integer")
         value))))

    (define (manifest-kind-default source-kind target)
      "Return the default manifest kind for SOURCE-KIND and TARGET."
      (cond
       ((or target (library-symbol-eq? source-kind 'alias)) 'library-alias)
       ((library-symbol-eq? source-kind 'primitive) 'primitive-library)
       (else 'library)))

    (define (manifest-api-version-default visibility target)
      "Return default api-version metadata for VISIBILITY and TARGET."
      (cond
       (target (list 'inherits target))
       ((or (library-symbol-eq? visibility 'internal-runtime)
            (library-symbol-eq? visibility 'internal-agent-primitive)
            (library-symbol-eq? visibility 'host-adapter))
        'internal)
       (else '(compat 0))))

    (define (manifest-source-version-default source-kind)
      "Return default source-version metadata for SOURCE-KIND."
      (if (or (library-symbol-eq? source-kind 'base-snapshot)
              (library-symbol-eq? source-kind 'primitive)
              (library-symbol-eq? source-kind 'derived))
          'runtime
          'unknown))

    (define (manifest-realization-default source-kind)
      "Return default realization metadata for SOURCE-KIND."
      (cond
       ((library-symbol-eq? source-kind 'portable-source) 'portable-source)
       ((library-symbol-eq? source-kind 'primitive) 'host-primitive)
       ((library-symbol-eq? source-kind 'alias) 'alias)
       ((library-symbol-eq? source-kind 'base-snapshot) 'runtime-snapshot)
       ((library-symbol-eq? source-kind 'derived) 'derived)
       ((library-symbol-eq? source-kind 'facade) 'shim)
       (source-kind source-kind)
       (else 'unknown)))

    (define (manifest-source-path source)
      "Return path from manifest SOURCE metadata, or #f."
      (and source
           (pair? source)
           (let ((parts (proper-list-elements source "manifest source")))
             (and (= (length parts) 2)
                  (library-symbol-eq? (car parts) 'path)
                  (string? (cadr parts))
                  (cadr parts)))))

    (define (manifest-source-implementation-id source)
      "Return implementation id from manifest SOURCE metadata, or #f."
      (and source
           (pair? source)
           (let ((parts (proper-list-elements source "manifest source")))
             (and (= (length parts) 2)
                  (library-symbol-eq? (car parts) 'implementation-id)
                  (collection-manifest-symbol
                   (cadr parts)
                   "manifest source implementation-id")))))

    (define (manifest-source-with-path source path)
      "Return SOURCE normalized to resolved PATH when SOURCE is a path datum."
      (if (and source path (pair? source))
          (let ((parts (proper-list-elements source "manifest source")))
            (if (and (= (length parts) 2) (library-symbol-eq? (car parts)
              'path))
                (list 'path path)
                source))
          source))

    (define (manifest-source-default source source-file target
      implementation-id)
      "Return normalized source metadata."
      (cond
       (source source)
       (source-file (list 'path source-file))
       (target (list 'target target))
       (implementation-id (list 'implementation-id implementation-id))
       (else 'unknown)))

    (define (manifest-documentation-summary documentation)
      "Return summary text from DOCUMENTATION metadata, or #f."
      (let loop ((rest (if documentation
                           (proper-list-elements
                            documentation
                            "manifest documentation")
                           '())))
        (cond
         ((null? rest) #f)
         ((pair? (car rest))
          (let ((parts
                 (proper-list-elements
                  (car rest)
                  "manifest documentation entry")))
            (if (and (= (length parts) 2)
                     (library-symbol-eq? (car parts) 'summary)
                     (string? (cadr parts)))
                (cadr parts)
                (loop (cdr rest)))))
         (else (loop (cdr rest))))))

    (define (manifest-documentation-default documentation summary)
      "Return DOCUMENTATION or summary-derived documentation metadata."
      (cond
       (documentation documentation)
       (summary (list (list 'summary summary)))
       (else #f)))

    (define (manifest-provenance-default provenance origin source-id)
      "Return PROVENANCE or a minimal origin/source-id record."
      (if provenance
          provenance
          (if source-id
              (list (list 'origin origin) (list 'source-id source-id))
              (list (list 'origin origin)))))

    (define (manifest-normalized-dependency entry description)
      "Return dependency ENTRY as a normalized library key."
      (let ((parts (and (pair? entry) (proper-list-elements/maybe entry))))
        (if (and parts (library-symbol-eq? (car parts) 'library) (pair? (cdr
          parts)))
            (library-name-key (cadr parts))
            (library-name-key entry))))

    (define (manifest-library-list value description)
      "Return VALUE normalized as a list of dependency library-name keys."
      (if value
          (map
           (lambda (entry)
             (manifest-normalized-dependency entry description))
           (proper-list-elements value description))
          '()))

    (define (collection-manifest-target value)
      "Return VALUE normalized as a library key, or #f."
      (if value (library-name-key value) #f))

    (define (collection-manifest-default-visibility status)
      "Return the default visibility implied by STATUS."
      (if (library-symbol-eq? status 'alias) 'alias 'public))

    (define (collection-manifest-catalog-source-file
             spec source-kind source-file)
      "Return manifest-root-relative SOURCE-FILE for SPEC, or #f."
      (if (and source-kind source-file)
          (string-append (collection-entry-field spec 'source-root "")
                         source-file)
          #f))

    (define (manifest-source-library-source-entry source-file key root)
      "Return source entry for ROOT-relative SOURCE-FILE owned by KEY."
      (let ((cache-key
             (list root
                   source-file
                   key
                   (consent-library-search-directory-list))))
        (let ((cached (assoc/equal cache-key
          manifest-source-library-source-cache)))
          (if cached
              (cdr cached)
              (let ((entry
                     (if root
                         (let* ((path (library-root-file root source-file))
                                (source (library-read-file/maybe path)))
                           (and source (cons path source)))
                         (resolve-source-entry
                          source-file
                          (list source-file)))))
                (if entry
                    (begin
                      (set! manifest-source-library-source-cache
                            (cons (cons cache-key entry)
                                  manifest-source-library-source-cache))
                      entry)
                    (eval-error "manifest source library file is not readable"
                                (list key source-file))))))))

    (define (manifest-source-library-source source-file key root)
      "Return source text for ROOT-relative SOURCE-FILE owned by KEY."
      (cdr (manifest-source-library-source-entry source-file key root)))

    (define (collection-manifest-entry entry spec)
      "Return catalog metadata parsed from collection manifest ENTRY and SPEC.\
"
      (let* ((key
              (library-name-key
               (collection-manifest-field entry 'name #f)))
             (status
              (let ((value (collection-manifest-field
                            entry 'status #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest status")
                    'implemented)))
             (visibility
              (let ((value (collection-manifest-field
                            entry 'visibility #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest visibility")
                    (collection-manifest-default-visibility status))))
             (layer
              (let ((value (collection-manifest-field entry 'layer #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest layer")
                    #f)))
             (availability
              (let ((value (collection-manifest-field
                            entry 'availability #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest availability")
                    'required)))
             (category
              (let ((value (collection-manifest-field entry 'category #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest category")
                    (collection-entry-field spec 'category #f))))
             (availability-condition
              (collection-manifest-field
               entry 'availability-condition #f))
             (root
              (collection-entry-field spec 'root #f))
             (root-kind
              (collection-entry-field spec 'root-kind #f))
             (target
              (collection-manifest-target
               (collection-manifest-field entry 'target #f)))
             (source-kind
              (or (collection-manifest-source-kind
                   (collection-manifest-field entry 'source-kind #f))
                  (and target 'alias)))
             (schema-version
              (manifest-nonnegative-integer
               (collection-manifest-field entry 'schema-version #f)
               "collection manifest schema-version"
               manifest-schema-version))
             (kind
              (let ((value (collection-manifest-field entry 'kind #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest kind")
                    (manifest-kind-default source-kind target))))
             (source
              (collection-manifest-field entry 'source #f))
             (implementation-id
              (manifest-source-implementation-id source))
             (primitive-overlay-library
              (collection-manifest-target
               (collection-manifest-field
                entry 'primitive-overlay-library #f)))
             (implementation-resolver
              (collection-manifest-field-values
               entry
               'implementation-resolver))
             (primitive-exports
              (primitive-library-normalize-exports
               (collection-manifest-field-values entry 'primitive-exports)
               "collection manifest primitive-exports"))
             (exports-absent (list 'exports-absent))
             (source-file
              (collection-manifest-catalog-source-file
               spec
               source-kind
               (manifest-source-path source)))
             (dependencies
              (manifest-library-list
               (collection-manifest-field entry 'dependencies #f)
               "collection manifest dependencies"))
             (aliases
              (manifest-library-list
               (collection-manifest-field entry 'aliases #f)
               "collection manifest aliases"))
             (exports-declared?
              (collection-manifest-field-present? entry 'exports))
             (exports
              (let ((value (collection-manifest-field
                            entry 'exports exports-absent)))
                (if (library-symbol-eq? value exports-absent)
                    exports-absent
                    (library-catalog-require-symbol-list
                     value
                     "collection manifest exports"))))
             (summary
              (collection-manifest-field entry 'summary #f))
             (owner
              (let ((value (collection-manifest-field entry 'owner #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest owner")
                    (collection-entry-field spec 'category #f))))
             (provider
              (let ((value (collection-manifest-field entry 'provider #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest provider")
                    'repo-source)))
             (api-version
              (collection-manifest-field entry 'api-version #f))
             (source-version
              (collection-manifest-field entry 'source-version #f))
             (realization
              (let ((value (collection-manifest-field entry 'realization #f)))
                (if value
                    (collection-manifest-symbol
                     value
                     "collection manifest realization")
                    #f)))
             (effects
              (collection-manifest-field entry 'effects #f))
             (capabilities
              (collection-manifest-field entry 'capabilities #f))
             (documentation
              (collection-manifest-field entry 'documentation #f))
             (verification
              (collection-manifest-field entry 'verification #f))
             (provenance
              (collection-manifest-field entry 'provenance #f))
             (canonical
              (collection-manifest-field
               entry
               'canonical
               (not (and target (library-symbol-eq? source-kind 'alias))))))
        (if (not (= schema-version manifest-schema-version))
            (eval-error
             "unsupported collection manifest schema-version"
             schema-version))
        (if (not exports-declared?)
            (if (and target (library-symbol-eq? source-kind 'alias))
                (set! exports '())
                (eval-error "built-in manifest entry must declare exports"
                            key)))
        (if (and summary (not (string? summary)))
            (eval-error "collection manifest summary must be a string or #f"
                        summary))
        (set! documentation
              (manifest-documentation-default documentation summary))
        (if (not summary)
            (set! summary (manifest-documentation-summary documentation)))
        (if (not api-version)
            (set! api-version
                  (manifest-api-version-default visibility target)))
        (if (not source-version)
            (set! source-version
                  (manifest-source-version-default source-kind)))
        (if (not realization)
            (set! realization
                  (manifest-realization-default source-kind)))
        (set! source (manifest-source-with-path source source-file))
        (set! source
              (manifest-source-default
               source source-file target implementation-id))
        (set! provenance
              (manifest-provenance-default
               provenance
               'repo
               (collection-entry-field spec 'source-id #f)))
        (list
         (list 'name key)
         (list 'schema-version schema-version)
         (list 'kind kind)
         (list 'category category)
         (list 'status status)
         (list 'source-kind source-kind)
         (list 'implementation-id implementation-id)
         (list 'primitive-overlay-library primitive-overlay-library)
         (list 'implementation-resolver implementation-resolver)
         (list 'primitive-exports primitive-exports)
         (list 'visibility visibility)
         (list 'layer layer)
         (list 'owner owner)
         (list 'provider provider)
         (list 'availability availability)
         (list 'availability-condition availability-condition)
         (list 'api-version api-version)
         (list 'source-version source-version)
         (list 'realization realization)
         (list 'source source)
         (list 'root root)
         (list 'root-kind root-kind)
         (list 'source-file source-file)
         (list 'aliases aliases)
         (list 'target target)
         (list 'exports-declared? exports-declared?)
         (list 'exports exports)
         (list 'dependencies dependencies)
         (list 'effects effects)
         (list 'capabilities capabilities)
         (list 'documentation documentation)
         (list 'verification verification)
         (list 'provenance provenance)
         (list 'canonical canonical)
         (list 'origin 'built-in-seed)
         (list 'source-id (collection-entry-field spec 'source-id #f))
         (list 'summary summary))))

    (define (library-collection-manifest-entries)
      "Return collection-manifest metadata for configured manifest roots."
      (let ((cache-key (library-manifest-root-cache-key)))
        (if (and library-collection-manifest-cache
                 (library-datum-equal? (car library-collection-manifest-cache)
                   cache-key))
            (cadr library-collection-manifest-cache)
            (let ((entries
                   (apply
                    append
                    (map
                     (lambda (spec)
                       (map
                        (lambda (entry)
                          (collection-manifest-entry entry spec))
                        (proper-list-elements
                         (collection-manifest-library-value spec)
                         "collection manifest entries")))
                     (library-collection-manifest-specs)))))
              (set! library-collection-manifest-cache
                    (list cache-key entries))
              entries))))

    (define (library-collection-manifest-entry key)
      "Return collection-manifest metadata for library KEY, or #f."
      (let loop ((entries (library-collection-manifest-entries)))
        (cond
         ((null? entries) #f)
         ((library-datum-equal? key (collection-entry-field (car entries) 'name
           '()))
          (car entries))
         (else (loop (cdr entries))))))

    (define (source-library-export-names form)
      "Return external export names declared by source library FORM."
      (apply append
             (map
              (lambda (declaration)
                (if (form-named? declaration 'export)
                    (map cdr
                         (export-specs
                          (cdr
                           (proper-list-elements
                            declaration
                            "source export"))))
                    '()))
              (cddr
               (proper-list-elements form "source library")))))

    (define (library-catalog-keys)
      "Return repo-owned library keys in manifest catalog order."
      (map
       (lambda (entry)
         (collection-entry-field entry 'name '()))
       (library-collection-manifest-entries)))

    (define (library-catalog-source-file key)
      "Return public catalog source path for KEY, or #f."
      (collection-entry-field
       (library-collection-manifest-entry key)
       'source-file
       #f))

    (define (library-catalog-category key)
      "Return the public catalog category for KEY."
      (collection-entry-field
       (library-collection-manifest-entry key)
       'category
       'library))

    (define (library-visibility key)
      "Return KEY's public/internal visibility tier from manifests."
      (or (collection-entry-field
           (library-collection-manifest-entry key)
           'visibility
           #f)
          'public))

    (define (library-visibility-internal? visibility)
      "Report whether VISIBILITY requires internal-library posture."
      (or (library-symbol-eq? visibility 'internal-runtime)
          (library-symbol-eq? visibility 'internal-agent-primitive)
          (library-symbol-eq? visibility 'internal-agent-model)))

    (define (library-availability-condition-satisfied? condition)
      "Report whether manifest availability CONDITION is satisfied."
      (cond
       ((not condition) #t)
       ((and (pair? condition)
             (library-symbol-eq? (car condition) 'host)
             (library-symbol-eq? (cadr condition) 'emacs))
        #f)
       (else #f)))

    (define (library-entry-available? entry)
      "Report whether manifest ENTRY is available on this host."
      (and entry
           (library-availability-condition-satisfied?
            (collection-entry-field entry 'availability-condition #f))))

    (define (source-library-internal-imports-allowed?)
      "Report whether a trusted source library is loading dependencies."
      (> source-library-internal-import-depth 0))

    (define (library-internal-import-allowed? context)
      "Report whether CONTEXT may import internal libraries."
      (or (source-library-internal-imports-allowed?)
          (context-internal-libraries-allowed? context)))

    (define (ensure-library-import-allowed key context)
      "Reject KEY when CONTEXT lacks the required internal posture."
      (if (and (library-visibility-internal? (library-visibility key))
               (not (library-internal-import-allowed? context)))
          (eval-error
           "internal library import requires internal-libraries-allowed"
           key)))

    (define (ensure-library-entry-import-allowed key entry context)
      "Reject catalog ENTRY when CONTEXT lacks its required import posture."
      (let ((visibility
             (if entry
                 (library-catalog-field entry 'visibility (library-visibility
                   key))
                 (library-visibility key))))
        (if (and (library-visibility-internal? visibility)
                 (not (library-internal-import-allowed? context)))
            (eval-error
             "internal library import requires internal-libraries-allowed"
             key))))

    (define (library-catalog-source-kind key)
      "Return the implementation source kind for KEY."
      (collection-entry-field
       (library-collection-manifest-entry key)
       'source-kind
       #f))

    (define (library-catalog-source-backed? key)
      "Report whether KEY is backed by a public source library."
      (and (library-catalog-source-file key) #t))

    (define (library-catalog-source-form key)
      "Return KEY's define-library form when KEY is source-backed."
      (let ((entry (library-collection-manifest-entry key)))
        (if (collection-entry-field entry 'source-file #f)
            (source-library-form
             key
             (manifest-source-library-source
              (collection-entry-field entry 'source-file #f)
              key
              (collection-entry-field entry 'root #f))
             "manifest source library")
            #f)))

    (define (library-catalog-private-context)
      "Return a fresh context/environment pair for catalog export discovery."
      (let ((context (new-eval-context
                      '((internal-libraries-allowed . #t))))
            (environment (consent-make-base-environment)))
        (set-context-interaction-environment! context environment)
        (ensure-base-syntax! context environment)
        (cons context environment)))

    (define (library-catalog-resolved-export-names key)
      "Resolve KEY in a private context and return exported binding names."
      (let* ((pair (library-catalog-private-context))
             (context (car pair))
             (environment (cdr pair))
             (library (resolve-library key context environment)))
        (map library-binding-name (library-exports library))))

    (define (library-catalog-export-names key)
      "Return exported binding names for cataloged library KEY."
      (guard (condition (else '()))
        (let ((manifest-entry (library-collection-manifest-entry key)))
          (cond
           ((collection-entry-field manifest-entry 'exports-declared? #f)
            (collection-entry-field manifest-entry 'exports '()))
           ((collection-entry-field manifest-entry 'target #f)
            (library-catalog-export-names
             (collection-entry-field manifest-entry 'target #f)))
           ((library-catalog-source-backed? key)
            (source-library-export-names
             (library-catalog-source-form key)))
           ((library-datum-equal? key scheme-base-library-key)
            (map (lambda (spec) (second (library-assq 'name spec)))
                 (consent-base-binding-specs)))
           (else
            (library-catalog-resolved-export-names key))))))

    (define (library-catalog-aliases key)
      "Return aliases that resolve to library KEY."
      (let loop ((entries (library-collection-manifest-entries))
                 (result '()))
        (cond
         ((null? entries) (reverse result))
         ((library-datum-equal? key (collection-entry-field (car entries)
           'target #f))
          (loop (cdr entries)
                (cons (collection-entry-field (car entries) 'name '())
                      result)))
         (else (loop (cdr entries) result)))))

    (define (library-catalog-dependencies key)
      "Return manifest dependency names for KEY when known."
      (let ((manifest-entry (library-collection-manifest-entry key)))
        (if manifest-entry
            (collection-entry-field manifest-entry 'dependencies '())
            '())))

    (define (library-catalog-invalidate!)
      "Clear cached catalog entries after catalog inputs change."
      (set! library-catalog-cache #f)
      (set! library-collection-manifest-cache #f)
      consent-unspecified)

    (define (library-catalog-entry-field entry field default)
      "Return FIELD from catalog ENTRY, or DEFAULT when absent."
      (let ((cell (library-assq field entry)))
        (if cell (cadr cell) default)))

    (define (library-catalog-manifest-field fields field default)
      "Return FIELD's value from manifest FIELDS, or DEFAULT."
      (let ((cell (library-assq field fields)))
        (if cell (cadr cell) default)))

    (define (library-catalog-manifest-field-values fields field)
      "Return every value for FIELD from manifest FIELDS."
      (let ((cell (library-assq field fields)))
        (if cell (cdr cell) '())))

    (define (library-catalog-manifest-field-present? fields field)
      "Report whether manifest FIELDS contains FIELD."
      (and (library-assq field fields) #t))

    (define (library-catalog-require-symbol value description)
      "Return VALUE when it is a symbol, else raise a catalog diagnostic error\
."
      (if (library-symbol? value)
          value
          (eval-error
           (string-append description " must be a symbol")
           value)))

    (define (library-catalog-require-source-file value)
      "Return VALUE when it is #f or a string source path."
      (if (or (not value) (string? value))
          value
          (eval-error "catalog source-file must be a string or #f" value)))

    (define (library-catalog-require-symbol-list value description)
      "Return VALUE when it is a list of symbols."
      (let ((parts (proper-list-elements value description)))
        (for-each
         (lambda (part)
           (if (not (library-symbol? part))
               (eval-error
                (string-append description " entries must be symbols")
                part)))
         parts)
        parts))

    (define (library-catalog-require-library-list value description)
      "Return VALUE normalized as a list of library keys."
      (manifest-library-list value description))

    (define (library-catalog-require-target value)
      "Return VALUE normalized as a library key, or #f."
      (if value (library-name-key value) #f))

    (define (library-catalog-normalized-source-kind value target)
      "Return catalog source-kind from manifest VALUE and TARGET."
      (or (collection-manifest-source-kind value)
          (and target 'alias)
          'manifest))

    (define (library-catalog-manifest-library form origin source-id)
      "Validate one manifest library FORM for ORIGIN and SOURCE-ID."
      (let ((parts (proper-list-elements form "catalog library entry")))
        (if (or (null? parts)
                (not (or (identifier-named? (car parts) 'manifest-entry)
                         (identifier-named? (car parts)
                                            'manifest-index-entry))))
            (eval-error
             "catalog entry must begin with manifest-entry or manifest-index-e\
ntry"
             form))
        (let* ((fields (cdr parts))
               (index-entry?
                (identifier-named? (car parts) 'manifest-index-entry))
               (name (library-name-key
                      (library-catalog-manifest-field fields 'name #f)))
               (status
                (library-catalog-require-symbol
                 (library-catalog-manifest-field fields 'status 'available)
                 "catalog status"))
               (visibility
                (library-catalog-require-symbol
                 (library-catalog-manifest-field fields 'visibility 'public)
                 "catalog visibility"))
               (aliases
                (library-catalog-require-library-list
                 (library-catalog-manifest-field fields 'aliases '())
                 "catalog aliases"))
               (target
                (library-catalog-require-target
                 (library-catalog-manifest-field fields 'target #f)))
               (source-kind
                (library-catalog-normalized-source-kind
                 (library-catalog-manifest-field fields 'source-kind #f)
                 target))
               (availability
                (library-catalog-require-symbol
                 (library-catalog-manifest-field fields 'availability
                   'required)
                 "catalog availability"))
               (availability-condition
                (library-catalog-manifest-field
                 fields
                 'availability-condition
                 #f))
               (schema-version
                (manifest-nonnegative-integer
                 (library-catalog-manifest-field fields 'schema-version #f)
                 "catalog schema-version"
                 manifest-schema-version))
               (kind
                (library-catalog-require-symbol
                 (library-catalog-manifest-field
                  fields
                  'kind
                  (manifest-kind-default source-kind target))
                 "catalog kind"))
               (category
                (library-catalog-require-symbol
                 (library-catalog-manifest-field
                  fields
                  'category
                  (if index-entry? 'alias 'library))
                 "catalog category"))
               (source
                (library-catalog-manifest-field fields 'source #f))
               (implementation-id
                (manifest-source-implementation-id source))
               (primitive-overlay-library
                (library-catalog-require-target
                 (library-catalog-manifest-field
                  fields
                  'primitive-overlay-library
                  #f)))
               (implementation-resolver
                (library-catalog-manifest-field-values
                 fields
                 'implementation-resolver))
               (primitive-exports
                (primitive-library-normalize-exports
                 (library-catalog-manifest-field-values
                  fields
                  'primitive-exports)
                 "catalog primitive-exports"))
               (source-file
                (manifest-source-path source))
               (exports-declared?
                (library-catalog-manifest-field-present? fields 'exports))
               (exports
                (library-catalog-require-symbol-list
                 (library-catalog-manifest-field fields 'exports '())
                 "catalog exports"))
               (dependencies
                (library-catalog-require-library-list
                 (library-catalog-manifest-field fields 'dependencies '())
                 "catalog dependencies"))
               (summary
                (library-catalog-manifest-field fields 'summary #f))
               (owner
                (library-catalog-require-symbol
                 (library-catalog-manifest-field fields 'owner 'project)
                 "catalog owner"))
               (provider
                (library-catalog-require-symbol
                 (library-catalog-manifest-field fields 'provider origin)
                 "catalog provider"))
               (api-version
                (library-catalog-manifest-field fields 'api-version #f))
               (source-version
                (library-catalog-manifest-field fields 'source-version #f))
               (realization
                (library-catalog-require-symbol
                 (library-catalog-manifest-field
                  fields
                  'realization
                  (manifest-realization-default source-kind))
                 "catalog realization"))
               (effects
                (library-catalog-manifest-field fields 'effects #f))
               (capabilities
                (library-catalog-manifest-field fields 'capabilities #f))
               (documentation
                (library-catalog-manifest-field fields 'documentation #f))
               (verification
                (library-catalog-manifest-field fields 'verification #f))
               (provenance
                (library-catalog-manifest-field fields 'provenance #f))
               (canonical
                (library-catalog-manifest-field
                 fields
                 'canonical
                 (not (and target (library-symbol-eq? source-kind 'alias))))))
          (if (not (= schema-version manifest-schema-version))
              (eval-error
               "unsupported catalog schema-version"
               schema-version))
          (if (and summary (not (string? summary)))
              (eval-error "catalog summary must be a string or #f" summary))
          (set! documentation
                (manifest-documentation-default documentation summary))
          (if (not summary)
              (set! summary (manifest-documentation-summary documentation)))
          (if (not api-version)
              (set! api-version
                    (manifest-api-version-default visibility target)))
          (if (not source-version)
              (set! source-version
                    (manifest-source-version-default source-kind)))
          (set! source (manifest-source-with-path source source-file))
          (set! source
                (manifest-source-default
                 source
                 source-file
                 target
                 implementation-id))
          (set! provenance
                (manifest-provenance-default provenance origin source-id))
          (list
           (list 'name name)
           (list 'schema-version schema-version)
           (list 'kind kind)
           (list 'category category)
           (list 'status status)
           (list 'source-kind source-kind)
           (list 'implementation-id implementation-id)
           (list 'primitive-overlay-library primitive-overlay-library)
           (list 'implementation-resolver implementation-resolver)
           (list 'primitive-exports primitive-exports)
           (list 'visibility visibility)
           (list 'owner owner)
           (list 'provider provider)
           (list 'layer (library-catalog-manifest-field fields 'layer #f))
           (list 'availability availability)
           (list 'availability-condition availability-condition)
           (list 'api-version api-version)
           (list 'source-version source-version)
           (list 'realization realization)
           (list 'source source)
           (list 'source-file source-file)
           (list 'aliases aliases)
           (list 'target target)
           (list 'exports-declared? exports-declared?)
           (list 'exports exports)
           (list 'dependencies dependencies)
           (list 'effects effects)
           (list 'capabilities capabilities)
           (list 'documentation documentation)
           (list 'verification verification)
           (list 'provenance provenance)
           (list 'canonical canonical)
           (list 'origin origin)
           (list 'source-id source-id)
           (list 'summary summary)))))

    (define (library-catalog-parse-manifest manifest origin source-id)
      "Validate MANIFEST and return catalog entries with ORIGIN and SOURCE-ID.\
"
      (let ((parts (proper-list-elements manifest "library catalog manifest")))
        (if (or (null? parts)
                (not (identifier-named? (car parts) 'library-catalog)))
            (eval-error "catalog manifest must begin with library-catalog"
                        manifest))
        (map
         (lambda (form)
           (library-catalog-manifest-library form origin source-id))
         (cdr parts))))

    (define (library-catalog-replace-source sources source-id entries)
      "Return SOURCES with SOURCE-ID replaced by ENTRIES at highest precedence\
."
      (let loop ((rest sources) (result '()))
        (cond
         ((null? rest) (cons (cons source-id entries) (reverse result)))
         ((library-datum-equal? source-id (caar rest))
          (append (reverse result)
                  (cons (cons source-id entries) (cdr rest))))
         (else (loop (cdr rest) (cons (car rest) result))))))

    (define (library-catalog-remove-source sources source-id)
      "Return (REMOVED? . SOURCES) after removing SOURCE-ID."
      (let loop ((rest sources) (result '()) (removed? #f))
        (cond
         ((null? rest) (cons removed? (reverse result)))
         ((library-datum-equal? source-id (caar rest))
          (loop (cdr rest) result #t))
         (else (loop (cdr rest) (cons (car rest) result) removed?)))))

    (define (library-catalog-source-entries sources)
      "Return all catalog entries stored in SOURCES."
      (if (null? sources)
          '()
          (apply append (map cdr sources))))

    (define (library-catalog-source-record/names kind source-id library-names)
      "Return a Scheme-readable catalog-source record for LIBRARY-NAMES."
      (list 'catalog-source
            (list 'kind kind)
            (list 'id source-id)
            (list 'libraries library-names)))

    (define (library-catalog-source-record kind source-id entries)
      "Return a Scheme-readable catalog-source record."
      (library-catalog-source-record/names
       kind
       source-id
       (map (lambda (entry)
              (library-catalog-entry-field entry 'name '()))
            entries)))

    (define (consent-library-catalog-add-manifest! source-id manifest)
      "Add or replace an ad-hoc catalog MANIFEST named SOURCE-ID."
      #((parameters
         (source-id (type (or symbol string))
          (description "Identifier for the ad-hoc manifest source."))
         (manifest (type list)
          (description "A `(library-catalog ...)' manifest datum.")))
        (returns (type list)
         (description "A catalog-source record for the registered manifest."))
        (effects state-read state-write allocation error))
      (let ((entries
             (library-catalog-parse-manifest
              manifest
              'ad-hoc-manifest
              source-id)))
        (set! library-catalog-ad-hoc-manifests
              (library-catalog-replace-source
               library-catalog-ad-hoc-manifests
               source-id
               entries))
        (library-catalog-invalidate!)
        (library-catalog-source-record 'ad-hoc-manifest source-id entries)))

    (define (consent-library-catalog-remove-manifest! source-id)
      "Remove the ad-hoc catalog manifest named SOURCE-ID."
      #((parameters
         (source-id (type (or symbol string))
          (description "Identifier for the ad-hoc manifest source.")))
        (returns (type boolean)
         (description "#t when a manifest was removed, else #f."))
        (effects state-write))
      (let ((removed/sources
             (library-catalog-remove-source
              library-catalog-ad-hoc-manifests
              source-id)))
        (set! library-catalog-ad-hoc-manifests (cdr removed/sources))
        (library-catalog-invalidate!)
        (car removed/sources)))

    (define (consent-library-catalog-add-root! root manifest)
      "Add or replace an explicit manifest-root catalog input."
      #((parameters
         (root (type string)
          (description "Manifest root identifier or directory path."))
         (manifest (type list)
          (description "A `(library-catalog ...)' manifest datum.")))
        (returns (type list)
         (description "A catalog-source record for the registered root."))
        (effects state-read state-write allocation error))
      (if (not (string? root))
          (eval-error "catalog root must be a string" root))
      (let ((entries
             (map
              (lambda (entry)
                (append entry
                        (list (list 'root root)
                              (list 'root-kind 'manifest-root))))
              (library-catalog-parse-manifest
               manifest
               'manifest-root
               root))))
        (set! library-catalog-root-manifests
              (library-catalog-replace-source
               library-catalog-root-manifests
               root
               entries))
        (library-catalog-invalidate!)
        (library-catalog-source-record 'manifest-root root entries)))

    (define (consent-library-catalog-remove-root! root)
      "Remove an explicit manifest-root catalog input."
      #((parameters
         (root (type string)
          (description "Manifest root identifier or directory path.")))
        (returns (type boolean)
         (description "#t when a root was removed, else #f."))
        (effects state-write))
      (let ((removed/sources
             (library-catalog-remove-source
              library-catalog-root-manifests
              root)))
        (set! library-catalog-root-manifests (cdr removed/sources))
        (library-catalog-invalidate!)
        (car removed/sources)))

    (define (consent-library-catalog-refresh!)
      "Clear cached catalog entries and diagnostics."
      #((parameters)
        (returns (type boolean)
         (description "#t after catalog caches are refreshed."))
        (effects state-write))
      (set! library-catalog-diagnostics '())
      (library-catalog-invalidate!)
      #t)

    (define (library-catalog-entry key)
      "Return manifest-backed catalog metadata for library KEY."
      (let ((manifest-entry (library-collection-manifest-entry key)))
        (list
         (list 'name key)
         (list 'schema-version
               (collection-entry-field manifest-entry
                                       'schema-version
                                       manifest-schema-version))
         (list 'kind
               (collection-entry-field manifest-entry 'kind 'library))
         (list 'category
               (or (collection-entry-field manifest-entry 'category #f)
                   (library-catalog-category key)))
         (list 'status
               (or (collection-entry-field manifest-entry 'status #f)
                   'implemented))
         (list 'source-kind (library-catalog-source-kind key))
         (list 'implementation-id
               (collection-entry-field manifest-entry 'implementation-id #f))
         (list 'primitive-overlay-library
               (collection-entry-field
                manifest-entry
                'primitive-overlay-library
                #f))
         (list 'implementation-resolver
               (collection-entry-field
                manifest-entry
                'implementation-resolver
                #f))
         (list 'primitive-exports
               (collection-entry-field
                manifest-entry
                'primitive-exports
                '()))
         (list 'visibility
               (collection-entry-field manifest-entry 'visibility 'public))
         (list 'layer (collection-entry-field manifest-entry 'layer #f))
         (list 'owner (collection-entry-field manifest-entry 'owner #f))
         (list 'provider
               (collection-entry-field manifest-entry 'provider #f))
         (list 'availability
               (collection-entry-field manifest-entry 'availability 'required))
         (list 'availability-condition
               (collection-entry-field
                manifest-entry
                'availability-condition
                #f))
         (list 'api-version
               (collection-entry-field manifest-entry 'api-version #f))
         (list 'source-version
               (collection-entry-field manifest-entry 'source-version #f))
         (list 'realization
               (collection-entry-field manifest-entry 'realization #f))
         (list 'source (collection-entry-field manifest-entry 'source #f))
         (list 'root (collection-entry-field manifest-entry 'root #f))
         (list 'root-kind
               (collection-entry-field manifest-entry 'root-kind #f))
         (list 'source-file (library-catalog-source-file key))
         (list 'aliases
               (if manifest-entry
                   (collection-entry-field manifest-entry 'aliases '())
                   (library-catalog-aliases key)))
         (list 'target
               (or (collection-entry-field manifest-entry 'target #f)
                   #f))
         (list 'exports-declared?
               (collection-entry-field
                manifest-entry
                'exports-declared?
                #f))
         (list 'exports (library-catalog-export-names key))
         (list 'dependencies (library-catalog-dependencies key))
         (list 'effects (collection-entry-field manifest-entry 'effects #f))
         (list 'capabilities
               (collection-entry-field manifest-entry 'capabilities #f))
         (list 'documentation
               (collection-entry-field manifest-entry 'documentation #f))
         (list 'verification
               (collection-entry-field manifest-entry 'verification #f))
         (list 'provenance
               (collection-entry-field manifest-entry 'provenance #f))
         (list 'canonical
               (collection-entry-field manifest-entry 'canonical #f))
         (list 'origin 'built-in-seed)
         (list 'source-id 'built-in-seed)
         (list 'summary
               (collection-entry-field manifest-entry 'summary #f)))))

    (define (library-catalog-field entry field default)
      "Return FIELD from catalog ENTRY, or DEFAULT when absent."
      (let ((cell (library-assq field entry)))
        (if cell (cadr cell) default)))

    (define (library-catalog-duplicate-diagnostic entry previous)
      "Return a diagnostic for duplicate ENTRY shadowed by PREVIOUS."
      (list 'catalog-diagnostic
            (list 'kind 'duplicate-library)
            (list 'name (library-catalog-field entry 'name '()))
            (list 'kept-source
                  (library-catalog-field previous 'source-id #f))
            (list 'ignored-source
                  (library-catalog-field entry 'source-id #f))))

    (define (library-catalog-deduplicate entries)
      "Return catalog ENTRIES under first-wins deterministic precedence."
      (let loop ((rest entries) (seen '()) (result '()) (diagnostics '()))
        (if (null? rest)
            (begin
              (set! library-catalog-diagnostics (reverse diagnostics))
              (reverse result))
            (let* ((entry (car rest))
                   (name (library-catalog-field entry 'name '()))
                   (previous (assoc/equal name seen)))
              (if previous
                  (loop (cdr rest)
                        seen
                        result
                        (cons
                         (library-catalog-duplicate-diagnostic
                          entry
                          (cdr previous))
                         diagnostics))
                  (loop (cdr rest)
                        (cons (cons name entry) seen)
                        (cons entry result)
                        diagnostics))))))

    (define (library-catalog-built-in-entries)
      "Return built-in seed catalog entries."
      (map library-catalog-entry (library-catalog-keys)))

    (define (library-catalog-candidate-entries)
      "Return all catalog input entries in precedence order."
      (append
       (library-catalog-source-entries library-catalog-ad-hoc-manifests)
       (library-catalog-source-entries library-catalog-root-manifests)
       (library-catalog-built-in-entries)))

    (define (consent-library-catalog-sources)
      "Return Scheme-readable catalog source records."
      #((parameters)
        (returns (type list)
         (description "Catalog source records in precedence order."))
        (effects state-read state-write allocation host-eval error))
      (append
       (map
        (lambda (source)
          (library-catalog-source-record
           'ad-hoc-manifest
           (car source)
           (cdr source)))
        library-catalog-ad-hoc-manifests)
       (map
        (lambda (source)
          (library-catalog-source-record
           'manifest-root
           (car source)
           (cdr source)))
        library-catalog-root-manifests)
       (list
        (library-catalog-source-record/names
         'built-in-seed
         'built-in-seed
         (library-catalog-keys)))))

    (define (consent-library-catalog-diagnostics)
      "Return catalog diagnostics from the most recent catalog build."
      #((parameters)
        (returns (type list)
         (description "Scheme-readable catalog diagnostics."))
        (effects state-read state-write allocation host-eval error))
      (consent-library-catalog-entries)
      library-catalog-diagnostics)

    (define (library-catalog-name-part-text part)
      "Return PART as public library-name text."
      (cond
       ((library-symbol? part) (library-symbol-name part))
       ((number? part) (number->string part))
       ((consent-number? part) (number->string (consent-number-value part)))
       (else "")))

    (define (library-catalog-library-name-text key)
      "Return KEY formatted as an R7RS library-name string."
      (let loop ((parts key) (text "("))
        (cond
         ((null? parts) (string-append text ")"))
         ((null? (cdr parts))
          (loop (cdr parts)
                (string-append text
                               (library-catalog-name-part-text (car parts)))))
         (else
          (loop (cdr parts)
                (string-append text
                               (library-catalog-name-part-text (car parts))
                               " "))))))

    (define (library-catalog-string-prefix? prefix text)
      "Report whether TEXT starts with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (string=? prefix (substring text 0 prefix-length)))))

    (define (library-catalog-string-contains? text needle)
      "Report whether TEXT contains NEEDLE."
      (let ((text-length (string-length text))
            (needle-length (string-length needle)))
        (let loop ((index 0))
          (and (<= (+ index needle-length) text-length)
               (or (library-catalog-string-prefix?
                    needle
                    (substring text index text-length))
                   (loop (+ index 1)))))))

    (define (library-catalog-text-match? text needle)
      "Report whether TEXT matches lowercase NEEDLE."
      (and text
           (library-catalog-string-contains?
            (string-downcase text)
            needle)))

    (define (library-catalog-symbol-list-match? symbols needle)
      "Report whether any symbol in SYMBOLS matches NEEDLE."
      (let loop ((rest symbols))
        (cond
         ((null? rest) #f)
         ((library-catalog-text-match? (library-symbol-name (car rest)) needle)
           #t)
         (else (loop (cdr rest))))))

    (define (library-catalog-name-list-match? names needle)
      "Report whether any library name in NAMES matches NEEDLE."
      (let loop ((rest names))
        (cond
         ((null? rest) #f)
         ((library-catalog-text-match?
           (library-catalog-library-name-text (car rest))
           needle)
          #t)
         (else (loop (cdr rest))))))

    (define (library-catalog-entry-match? entry needle)
      "Report whether catalog ENTRY matches lowercase NEEDLE."
      (or
       (library-catalog-text-match?
        (library-catalog-library-name-text
         (library-catalog-field entry 'name '()))
        needle)
       (library-catalog-text-match?
        (library-symbol-name (library-catalog-field entry 'category 'library))
        needle)
       (library-catalog-text-match?
        (library-symbol-name (library-catalog-field entry 'source-kind
          'manifest))
        needle)
       (library-catalog-text-match?
        (library-symbol-name (library-catalog-field entry 'visibility 'public))
        needle)
       (library-catalog-text-match?
        (library-symbol-name (library-catalog-field entry 'status
          'implemented))
        needle)
       (library-catalog-text-match?
        (library-symbol-name (library-catalog-field entry 'origin
          'built-in-seed))
        needle)
       (library-catalog-text-match?
        (library-catalog-field entry 'source-file #f)
        needle)
       (let ((source-id (library-catalog-field entry 'source-id #f)))
         (library-catalog-text-match?
          (cond
           ((string? source-id) source-id)
           ((library-symbol? source-id) (library-symbol-name source-id))
           (else #f))
          needle))
       (library-catalog-text-match?
        (library-catalog-field entry 'summary #f)
        needle)
       (let ((target (library-catalog-field entry 'target #f)))
         (and target
              (library-catalog-text-match?
               (library-catalog-library-name-text target)
               needle)))
       (library-catalog-name-list-match?
        (library-catalog-field entry 'aliases '())
        needle)
       (library-catalog-name-list-match?
        (library-catalog-field entry 'dependencies '())
        needle)
       (library-catalog-symbol-list-match?
        (library-catalog-field entry 'exports '())
        needle)))

    (define (library-catalog-query-text query)
      "Return QUERY as catalog search text."
      (cond
       ((string? query) query)
       ((library-symbol? query) (library-symbol-name query))
       ((proper-library-name? query)
        (library-catalog-library-name-text (library-name-key query)))
       (else
        (eval-error
         "library search query must be a string, symbol, or library name"
         query))))

    (define (consent-library-catalog-entries)
      "Return manifest-backed catalog metadata for repo-owned libraries."
      #((parameters)
        (returns (type list)
         (description
          ("A list of library catalog field records for every repo-owned"
            "library known to the runtime manifest.")))
        (effects state-read state-write allocation host-eval error))
      (let ((cache-key (library-manifest-root-cache-key)))
        (if (and library-catalog-cache
                 (library-datum-equal? (car library-catalog-cache) cache-key))
            (cadr library-catalog-cache)
            (let ((entries
                   (library-catalog-deduplicate
                    (library-catalog-candidate-entries))))
              (set! library-catalog-cache
                    (list cache-key entries))
              entries))))

    (define (consent-library-catalog-entry library-name)
      "Return catalog metadata for LIBRARY-NAME, or #f when absent."
      #((parameters
         (library-name (type (list-of (or symbol exact-integer)))
          (description "R7RS library name to find in the catalog.")))
        (returns (type (or list boolean))
         (description
          ("The catalog field record for LIBRARY-NAME, or #f when the"
            "library is not cataloged.")))
        (effects state-read state-write allocation host-eval error))
      (let ((key (library-name-key library-name)))
        (let loop ((entries (consent-library-catalog-entries)))
          (cond
           ((null? entries) #f)
           ((library-datum-equal? key (library-catalog-field (car entries)
             'name '()))
            (car entries))
           (else (loop (cdr entries)))))))

    (define (consent-library-catalog-search query)
      "Return catalog entries matching QUERY."
      #((parameters
         (query (type (or string symbol list))
          (description
           ("Search text, symbol, or library name matched against catalog"
             "names, aliases, source paths, categories, and exports."))))
        (returns (type list)
         (description "Catalog field records matching QUERY."))
        (effects state-read state-write allocation host-eval error))
      (let ((needle (string-downcase (library-catalog-query-text query))))
        (let loop ((entries (consent-library-catalog-entries))
                   (result '()))
          (cond
           ((null? entries) (reverse result))
           ((library-catalog-entry-match? (car entries) needle)
            (loop (cdr entries) (cons (car entries) result)))
           (else (loop (cdr entries) result))))))

    (define (library-catalog-candidates library-name)
      "Return all catalog candidates for LIBRARY-NAME in precedence order."
      (let ((key (library-name-key library-name)))
        (let loop ((entries (library-catalog-candidate-entries))
                   (result '()))
          (cond
           ((null? entries) (reverse result))
           ((library-datum-equal? key (library-catalog-field (car entries)
             'name '()))
            (loop (cdr entries) (cons (car entries) result)))
           (else (loop (cdr entries) result))))))

    (define (library-resolution-field name value)
      "Return one Scheme-readable resolver field."
      (list name value))

    (define (library-record-root entry)
      "Return ENTRY's root category."
      (let ((origin (library-catalog-field entry 'origin #f))
            (root-kind (library-catalog-field entry 'root-kind #f))
            (source-kind (library-catalog-field entry 'source-kind #f))
            (category (library-catalog-field entry 'category #f))
            (owner (library-catalog-field entry 'owner #f))
            (name (library-catalog-field entry 'name '())))
        (cond
         ((library-symbol-eq? origin 'ad-hoc-manifest) 'ad-hoc-manifest)
         ((library-symbol-eq? origin 'manifest-root) 'manifest-root)
         ((library-symbol-eq? root-kind 'user) 'user)
         ((library-symbol-eq? source-kind 'base-snapshot) 'builtin)
         ((or (library-symbol-eq? category 'standard)
              (library-symbol-eq? category 'stdlib)
              (library-symbol-eq? owner 'stdlib)
              (and (pair? name)
                   (or (library-symbol-eq? (car name) 'srfi)
                       (library-symbol-eq? (car name) 'stdlib))))
          'stdlib-vendored)
         ((library-symbol-eq? source-kind 'primitive) 'host-adapter)
         ((library-symbol-eq? root-kind 'system) 'builtin)
         (else 'builtin))))

    (define (library-record-trust root)
      "Return trust label for ROOT."
      (cond
       ((library-symbol-eq? root 'ad-hoc-manifest) 'ad-hoc)
       ((library-symbol-eq? root 'manifest-root) 'explicit)
       ((library-symbol-eq? root 'user) 'user)
       ((library-symbol-eq? root 'host-adapter) 'host)
       ((or (library-symbol-eq? root 'stdlib-vendored) (library-symbol-eq? root
         'builtin)) 'bundled)
       (else 'unknown)))

    (define (library-entry-resolved-name entry seen)
      "Return ENTRY's final target key after alias expansion."
      (let ((key (library-catalog-field entry 'name '()))
            (target (library-catalog-field entry 'target #f)))
        (if (or (not target) (library-member key seen))
            key
            (let ((target-entry (consent-library-catalog-entry target)))
              (if target-entry
                  (library-entry-resolved-name
                   target-entry
                   (cons key seen))
                  target)))))

    (define (library-candidate-record entry)
      "Return ENTRY as a Scheme-readable library-candidate record."
      (let* ((root (library-record-root entry))
             (trust (library-record-trust root)))
        (list 'library-candidate
              (library-resolution-field
               'name
               (library-catalog-field entry 'name '()))
              (library-resolution-field 'root root)
              (library-resolution-field
               'source-id
               (library-catalog-field entry 'source-id #f))
              (library-resolution-field
               'source-kind
               (library-catalog-field entry 'source-kind 'manifest))
              (library-resolution-field
               'provider
               (library-catalog-field entry 'provider #f))
              (library-resolution-field 'trust trust))))

    (define (library-resolution-record name entry status reason loaded
      candidates)
      "Return a Scheme-readable library-resolution record."
      (let* ((key (library-name-key name))
             (resolved-key
              (if entry (library-entry-resolved-name entry '()) key))
             (root (and entry (library-record-root entry)))
             (trust (and root (library-record-trust root))))
        (append
         (list
          'library-resolution
          (library-resolution-field 'name key)
          (library-resolution-field 'resolved-name resolved-key)
          (library-resolution-field 'root root)
          (library-resolution-field
           'source-kind
           (and entry (library-catalog-field entry 'source-kind #f)))
          (library-resolution-field
           'source
           (and entry (library-catalog-field entry 'source #f)))
          (library-resolution-field
           'source-file
           (and entry (library-catalog-field entry 'source-file #f)))
          (library-resolution-field
           'visibility
           (and entry (library-catalog-field entry 'visibility #f)))
          (library-resolution-field
           'layer
           (and entry (library-catalog-field entry 'layer #f)))
          (library-resolution-field
           'owner
           (and entry (library-catalog-field entry 'owner #f)))
          (library-resolution-field
           'provider
           (and entry (library-catalog-field entry 'provider #f)))
          (library-resolution-field 'trust trust)
          (library-resolution-field
           'target
           (and entry (library-catalog-field entry 'target #f)))
          (library-resolution-field
           'availability
           (and entry (library-catalog-field entry 'availability #f)))
          (library-resolution-field
           'availability-condition
           (and entry (library-catalog-field
                       entry
                       'availability-condition
                       #f)))
          (library-resolution-field 'status status))
         (append
          (if reason (list (library-resolution-field 'reason reason)) '())
          (if loaded (list (library-resolution-field 'loaded? #t)) '())
          (if candidates
              (list
               (library-resolution-field
                'candidates
                (map library-candidate-record candidates)))
              '())))))

    (define (consent-library-resolve-record name context)
      "Return NAME's deterministic library-resolution record in CONTEXT."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to resolve."))
         (context (type eval-context)
          (description
            "Context whose internal-library posture is consulted.")))
        (returns (type list)
         (description "A library-resolution record."))
        (effects state-read state-write allocation error))
      (let* ((key (library-name-key name))
             (entry (consent-library-catalog-entry key)))
        (cond
         ((not entry)
          (library-resolution-record
           key
           #f
           'missing
           'missing-library
           #f
           #f))
         ((and (library-visibility-internal?
                (library-catalog-field entry 'visibility #f))
               (not (library-internal-import-allowed? context)))
          (append
           (library-resolution-record
            key
            entry
            'denied
            'internal-library
            #f
            #f)
           (list
            (library-resolution-field
             'required-posture
             'internal-libraries-allowed))))
         ((not (library-entry-available? entry))
          (library-resolution-record
           key
           entry
           'unavailable
           'availability-condition
           #f
           #f))
         (else
          (library-resolution-record
           key
           entry
           'resolved
           #f
           #f
           #f)))))

    (define (consent-library-load-record name context environment)
      "Load NAME into CONTEXT and return a resolution record."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to load."))
         (context (type eval-context)
          (description "Context whose registry receives the library."))
         (environment (type environment)
          (description "Environment used for loading source libraries.")))
        (returns (type list)
         (description "A library-resolution record."))
        (effects state-read state-write allocation error))
      (let* ((key (library-name-key name))
             (entry (consent-library-catalog-entry key)))
        (if (not entry)
            (library-resolution-record
             key
             #f
             'missing
             'missing-library
             #f
             #f)
            (begin
              (resolve-library key context environment)
              (library-resolution-record
               key
               entry
               'resolved
               #f
               #t
               #f)))))

    (define (library-dependency-solution name)
      "Return dependency closure and missing edges for NAME."
      (let ((seen '())
            (result '())
            (missing '()))
        (define (record-missing! key)
          (if (not (library-member key missing))
              (set! missing (cons key missing))))
        (define (record-dependency! dependency)
          (if (not (library-member dependency result))
              (set! result (cons dependency result)))
          (visit dependency))
        (define (visit key)
          (if (not (library-member key seen))
              (begin
                (set! seen (cons key seen))
                (let ((entry (consent-library-catalog-entry key)))
                  (if entry
                      (for-each
                       record-dependency!
                       (library-catalog-field entry 'dependencies '()))
                      (record-missing! key))))))
        (let ((entry (consent-library-catalog-entry (library-name-key name))))
          (for-each
           record-dependency!
           (if entry
               (library-catalog-field entry 'dependencies '())
               '())))
        (list (cons 'dependencies (reverse result))
              (cons 'missing-dependencies (reverse missing)))))

    (define (library-dependency-closure name)
      "Return transitive dependency keys for NAME in deterministic order."
      (cdr (library-assq 'dependencies (library-dependency-solution name))))

    (define (consent-library-solve-dependencies name)
      "Return a Scheme-readable dependency solution record for NAME."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name whose dependencies should be solved.")))
        (returns (type list)
         (description "A library-dependencies record."))
        (effects state-read state-write allocation error))
      (let* ((key (library-name-key name))
             (entry (consent-library-catalog-entry key)))
        (if entry
            (let* ((solution (library-dependency-solution key))
                   (dependencies
                    (cdr (library-assq 'dependencies solution)))
                   (missing-dependencies
                    (cdr (library-assq 'missing-dependencies solution))))
              (append
               (list 'library-dependencies
                     (library-resolution-field 'name key)
                     (library-resolution-field
                      'status
                      (if (null? missing-dependencies)
                          'resolved
                          'unsatisfied-dependency))
                     (library-resolution-field
                      'dependencies
                      dependencies))
               (if (null? missing-dependencies)
                   '()
                   (list
                    (library-resolution-field 'reason 'missing-dependency)
                    (library-resolution-field
                     'missing-dependencies
                     missing-dependencies)))))
            (list 'library-dependencies
                  (library-resolution-field 'name key)
                  (library-resolution-field 'status 'missing)
                  (library-resolution-field 'reason 'missing-library)
                  (library-resolution-field 'dependencies '())))))

    (define (library-path-record kind source-id entries precedence)
      "Return a Scheme-readable library-path record."
      (list 'library-path
            (library-resolution-field 'kind kind)
            (library-resolution-field 'id source-id)
            (library-resolution-field 'precedence precedence)
            (library-resolution-field
             'libraries
             (map
              (lambda (entry)
                (library-catalog-field entry 'name '()))
              entries))))

    (define (consent-library-paths)
      "Return active library path records in precedence order."
      #((parameters)
        (returns (type list)
         (description "Library path records."))
        (effects state-read state-write allocation host-eval error))
      (let ((precedence 0)
            (result '()))
        (for-each
         (lambda (source)
           (set! result
                 (cons
                  (library-path-record
                   'ad-hoc-manifest
                   (car source)
                   (cdr source)
                   precedence)
                  result))
           (set! precedence (+ precedence 1)))
         library-catalog-ad-hoc-manifests)
        (for-each
         (lambda (source)
           (set! result
                 (cons
                  (library-path-record
                   'manifest-root
                   (car source)
                   (cdr source)
                   precedence)
                  result))
           (set! precedence (+ precedence 1)))
         library-catalog-root-manifests)
        (set! result
              (cons
               (library-path-record
                'built-in-seed
                'built-in-seed
                (library-catalog-built-in-entries)
                precedence)
               result))
        (reverse result)))

    (define (library-candidate-names)
      "Return candidate names in first-seen order."
      (let loop ((entries (library-catalog-candidate-entries))
                 (seen '())
                 (result '()))
        (cond
         ((null? entries) (reverse result))
         ((library-member (library-catalog-field (car entries) 'name '()) seen)
          (loop (cdr entries) seen result))
         (else
          (let ((name (library-catalog-field (car entries) 'name '())))
            (loop (cdr entries)
                  (cons name seen)
                  (cons name result)))))))

    (define (library-conflict-record name)
      "Return conflict record for NAME, or #f when not conflicted."
      (let ((candidates (library-catalog-candidates name)))
        (if (and (pair? candidates) (pair? (cdr candidates)))
            (library-resolution-record
             name
             (car candidates)
             'conflict
             'duplicate-library
             #f
             candidates)
            #f)))

    (define (consent-library-conflicts . maybe-name)
      "Return catalog conflict records."
      #((parameters
         (maybe-name (type list)
          (description "Optional library name filter.")))
        (returns (type list)
         (description "Library-resolution records with status conflict."))
        (effects state-read state-write allocation host-eval error))
      (if (null? maybe-name)
          (let loop ((names (library-candidate-names)) (result '()))
            (if (null? names)
                (reverse result)
                (let ((record (library-conflict-record (car names))))
                  (loop (cdr names)
                        (if record (cons record result) result)))))
          (let ((record (library-conflict-record (car maybe-name))))
            (if record (list record) '()))))

    (define (consent-library-snapshot name context)
      "Return a reproducible resolution snapshot for NAME."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Root library name for the snapshot."))
         (context (type eval-context)
          (description "Context whose internal posture is consulted.")))
        (returns (type list)
         (description "A library-snapshot record."))
        (effects state-read state-write allocation host-eval error))
      (let* ((key (library-name-key name))
             (keys (cons key (library-dependency-closure key))))
        (list 'library-snapshot
              (library-resolution-field 'name key)
              (library-resolution-field 'status 'resolved)
              (library-resolution-field
               'resolved
               (map
                (lambda (entry-key)
                  (consent-library-resolve-record entry-key context))
                keys)))))

    (define (consent-srfi-number value)
      "Return VALUE as a non-negative SRFI number."
      (cond
       ((and (integer? value) (>= value 0)) value)
       ((and (consent-number? value)
             (library-symbol-eq? (consent-number-kind value) 'integer)
             (library-symbol-eq? (consent-number-exactness value) 'exact)
             (>= (consent-number-value value) 0))
        (consent-number-value value))
       (else
        (eval-error
         "SRFI number must be a non-negative exact integer"
         value))))

    (define (consent-srfi-library-name number)
      "Return canonical SRFI library name for NUMBER."
      #((parameters
         (number (type exact-integer)
          (description "Non-negative SRFI number.")))
        (returns (type list)
         (description "Canonical `(srfi N)' library name."))
        (effects error))
      (list 'srfi (consent-srfi-number number)))

    (define (consent-srfi-library-aliases number)
      "Return known aliases for SRFI NUMBER."
      #((parameters
         (number (type exact-integer)
          (description "Non-negative SRFI number.")))
        (returns (type list)
         (description "Known SRFI library aliases."))
        (effects state-read state-write allocation host-eval error))
      (let* ((name (consent-srfi-library-name number))
             (entry (consent-library-catalog-entry name)))
        (cons name
              (if entry
                  (library-catalog-field entry 'aliases '())
                  '()))))

    (define (consent-vendored-srfi-entry number)
      "Return catalog entry for vendored SRFI NUMBER, or #f."
      #((parameters
         (number (type exact-integer)
          (description "Non-negative SRFI number.")))
        (returns (type (or list boolean))
         (description "Catalog entry for the SRFI alias, or #f."))
        (effects state-read state-write allocation host-eval error))
      (consent-library-catalog-entry
       (consent-srfi-library-name number)))

    (define (vendored-srfi-implementation-entry entry)
      "Return the implementation manifest ENTRY represents."
      (let ((target (library-catalog-field entry 'target #f)))
        (if (and target
                 (library-symbol-eq? (library-catalog-field entry 'status #f)
                   'alias))
            (or (consent-library-catalog-entry target) entry)
            entry)))

    (define (vendored-srfi-import-names
             srfi-name
             entry
             implementation-entry)
      "Return import names for SRFI-NAME and its implementation ENTRY."
      (let loop ((rest
                  (append
                   (list srfi-name)
                   (library-catalog-field entry 'aliases '())
                   (library-catalog-field
                    implementation-entry
                    'aliases
                    '())
                   (list (library-catalog-field
                          implementation-entry
                          'name
                          #f))))
                 (seen '())
                 (result '()))
        (cond
         ((null? rest) (reverse result))
         ((not (car rest)) (loop (cdr rest) seen result))
         ((library-member (car rest) seen) (loop (cdr rest) seen result))
         (else
          (loop (cdr rest)
                (cons (car rest) seen)
                (cons (car rest) result))))))

    (define (vendored-srfi-name entry)
      "Return a compact SRFI record name derived from ENTRY."
      (let ((source-name
             (or (library-catalog-field entry 'target #f)
                 (library-catalog-field entry 'name #f))))
        (if (and (pair? source-name) (pair? (cdr source-name)))
            (cadr source-name)
            #f)))

    (define (vendored-srfi-provenance-field entry field)
      "Return FIELD from ENTRY provenance metadata."
      (library-catalog-manifest-field
       (library-catalog-field entry 'provenance '())
       field
       #f))

    (define (vendored-srfi-source-version-field entry field)
      "Return FIELD from ENTRY source-version metadata."
      (let ((source-version
             (library-catalog-field entry 'source-version #f)))
        (if (and (pair? source-version)
                 (library-symbol-eq? (car source-version) field)
                 (pair? (cdr source-version)))
            (cadr source-version)
            #f)))

    (define (vendored-srfi-tests entry)
      "Return test-status metadata from ENTRY verification."
      (or (library-catalog-manifest-field
           (library-catalog-field entry 'verification '())
           'test-status
           #f)
          '()))

    (define (vendored-srfi-classification entry implementation-entry)
      "Return bundle classification for ENTRY and IMPLEMENTATION-ENTRY."
      (let ((status (library-catalog-field entry 'status #f))
            (implementation-status
             (library-catalog-field implementation-entry 'status #f)))
        (cond
         ((or (library-symbol-eq? status 'built-in-shim)
              (library-symbol-eq? implementation-status 'built-in-shim)
              (library-symbol-eq? (library-catalog-field
                    implementation-entry
                    'realization
                    #f)
                   'shim))
          'shim)
         ((or (library-symbol-eq? implementation-status
           'vendored-adapted-implementation)
              (library-symbol-eq? (vendored-srfi-provenance-field
                    implementation-entry
                    'vendored?)
                   #t))
          'vendored-library)
         ((library-catalog-field entry 'target #f) 'alias)
         (else 'portable-library))))

    (define (vendored-srfi-record number srfi-name entry implementation-entry)
      "Return a vendored-srfi record from explicit catalog entries."
      (let ((srfi-number (consent-srfi-number number)))
        (if (not entry)
            (list 'vendored-srfi
                  (library-resolution-field 'number srfi-number)
                  (library-resolution-field 'name #f)
                  (library-resolution-field
                   'import-names
                   (list srfi-name))
                  (library-resolution-field 'status 'missing)
                  (library-resolution-field 'reason 'missing-srfi))
            (let* ((implementation-entry
                    (or implementation-entry entry))
                   (target (library-catalog-field entry 'target #f))
                   (dependencies
                    (library-catalog-field
                     implementation-entry
                     'dependencies
                     '()))
                   (upstream-revision
                    (or
                     (vendored-srfi-provenance-field
                      implementation-entry
                      'upstream-revision)
                     (vendored-srfi-source-version-field
                      implementation-entry
                      'upstream-revision))))
              (list
               'vendored-srfi
               (library-resolution-field 'number srfi-number)
               (library-resolution-field
                'name
                (vendored-srfi-name implementation-entry))
               (library-resolution-field
                'library
                (library-catalog-field implementation-entry 'name #f))
               (library-resolution-field 'target (or target #f))
               (library-resolution-field
                'classification
                (vendored-srfi-classification
                 entry
                 implementation-entry))
               (library-resolution-field
                'import-names
                (vendored-srfi-import-names
                 srfi-name
                 entry
                 implementation-entry))
               (library-resolution-field
                'source
                (or (library-catalog-field
                     implementation-entry
                     'source
                     #f)
                    #f))
               (library-resolution-field
                'source-url
                (or (vendored-srfi-provenance-field
                     implementation-entry
                     'upstream-source-url)
                    #f))
               (library-resolution-field
                'upstream-revision
                (or upstream-revision #f))
               (library-resolution-field
                'license
                (or (vendored-srfi-provenance-field
                     implementation-entry
                     'upstream-license)
                    #f))
               (library-resolution-field
                'local-license
                (or (vendored-srfi-provenance-field
                     implementation-entry
                     'local-license)
                    #f))
               (library-resolution-field
                'local-patches
                (or (vendored-srfi-provenance-field
                     implementation-entry
                     'local-patches)
                    '()))
               (library-resolution-field
                'dependencies
                (map
                 (lambda (dependency)
                   (list 'library dependency))
                 dependencies))
               (library-resolution-field
                'status
                (library-catalog-field implementation-entry 'status #f))
               (library-resolution-field
                'tests
                (vendored-srfi-tests implementation-entry)))))))

    (define (consent-vendored-srfi-record number)
      "Return the Scheme-readable SRFI vendor manifest record for NUMBER."
      #((parameters
         (number (type exact-integer)
          (description "Non-negative SRFI number.")))
        (returns (type list)
         (description "A vendored-srfi intake record."))
        (effects state-read state-write allocation host-eval error))
      (let* ((srfi-number (consent-srfi-number number))
             (srfi-name (consent-srfi-library-name srfi-number))
             (entry (consent-vendored-srfi-entry srfi-number)))
        (vendored-srfi-record
         srfi-number
         srfi-name
         entry
         (and entry (vendored-srfi-implementation-entry entry)))))

    (define (source-library-specs-for-category category description)
      "Return portable source metadata for CATEGORY using DESCRIPTION."
      (map
       (lambda (entry)
         (let ((key (collection-entry-field entry 'name '())))
           (list
            (list 'name key)
            (list 'exports
                  (source-library-export-names
                   (source-library-form
                    key
                    (manifest-source-library-source
                     (collection-entry-field entry 'source-file #f)
                     key
                     (collection-entry-field entry 'root #f))
                    description)))
            (list 'source-file (library-catalog-source-file key)))))
       (let loop ((entries (library-collection-manifest-entries))
                  (result '()))
         (cond
          ((null? entries) (reverse result))
          ((and (library-symbol-eq? (collection-entry-field
                      (car entries) 'category #f)
                     category)
                (library-symbol-eq? (collection-entry-field
                      (car entries) 'source-kind #f)
                     'portable-source))
           (loop (cdr entries) (cons (car entries) result)))
          (else (loop (cdr entries) result))))))

    (define (consent-standard-source-library-specs)
      "Public metadata accessor for standard libraries backed by source files.\
"
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed standard library.")))
        (effects state-read state-write))
      (source-library-specs-for-category
       'standard
       "standard source library"))

    (define (consent-stdlib-source-library-specs)
      "Public metadata accessor for stdlib libraries backed by source files."
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed stdlib library.")))
        (effects state-read state-write))
      (source-library-specs-for-category
       'stdlib
       "stdlib source library"))

    (define (consent-data-source-library-specs)
      "Public metadata accessor for data libraries backed by source files."
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed data library.")))
        (effects state-read state-write))
      (source-library-specs-for-category
       'data
       "data source library"))

    (define (library-registry-ref context key)
      "Return the registered library for KEY in CONTEXT, or #f."
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose library registry is searched.")))
         (key (type list)
          (description "Library registry key to look up.")))
        (returns (type (or library boolean))
         (description
           "The library registered under KEY, or #f when it is absent."))
        (effects state-read))
      (let ((cell (assoc/equal key (context-libraries context))))
        (if cell (cdr cell) #f)))

    (define (library-registry-set! context key library)
      "Store LIBRARY under KEY in CONTEXT's registry."
      #((parameters
         (context (type eval-context)
          (description
            ("Evaluation context whose library registry is updated.")))
         (key (type list)
          (description "Library registry key to associate with LIBRARY."))
         (library (type library)
          (description "Library object to store under KEY.")))
        (returns .
          ("An unspecified value after registering LIBRARY under KEY."))
        (effects state-write))
      (let replace ((rest (context-libraries context)) (prefix '()))
        (cond
         ((null? rest)
          (set-context-libraries!
           context
           (cons (cons key library) (context-libraries context))))
         ((library-datum-equal? key (caar rest))
          (set-context-libraries!
           context
           (append (reverse prefix)
                   (cons (cons key library) (cdr rest)))))
         (else
          (replace (cdr rest) (cons (car rest) prefix))))))

    (define (current-syntax-binding syntax-environment name)
      "Return NAME's binding from SYNTAX-ENVIRONMENT's current frame only."
      (let ((cell (library-assq name (syntax-environment-frame
        syntax-environment))))
        (if cell (cdr cell) #f)))

    (define (form-named? form name)
      "Report whether FORM is headed by identifier NAME."
      #((parameters
         (form . "Datum to test for a heading identifier.")
         (name (type symbol)
          (description "Symbol the form's head identifier must match.")))
        (returns (type boolean)
         (description
          ("#t when FORM is a pair whose head identifier is NAME, else"
            "#f.")))
        (effects pure))
      (and (pair? form) (identifier-named? (car form) name)))

    (define (import-form? form)
      "Report whether FORM is an import declaration."
      #((parameters
         (form . "Datum to test for an import declaration heading."))
        (returns (type boolean)
         (description
           ("#t when FORM is headed by the import identifier, else #f.")))
        (effects pure))
      (form-named? form 'import))

    (define (define-library-form? form)
      "Report whether FORM is a define-library declaration."
      #((parameters
         (form . ("Datum to test for a define-library declaration heading.")))
        (returns (type boolean)
         (description
          ("#t when FORM is headed by the define-library identifier,"
            "else #f.")))
        (effects pure))
      (form-named? form 'define-library))

    (define (library-binding-with-name binding name)
      "Return BINDING under exported NAME while preserving its target object."
      (make-library-binding
       name
       (library-binding-kind binding)
       (library-binding-object binding)
       (library-binding-library-key binding)))

    (define (same-library-binding? left right)
      "Report whether two library bindings refer to the same exported object."
      (and (library-binding? left)
           (library-binding? right)
           (library-symbol-eq? (library-binding-kind left)
             (library-binding-kind right))
           (library-symbol-eq? (library-binding-object left)
                (library-binding-object right))))

    (define (snapshot-library-bindings value-environment syntax-environment
                                       library-key)
      "Snapshot current value and syntax frames as exports for LIBRARY-KEY."
      (append
       (map (lambda (entry)
              (make-library-binding
               (car entry)
               'value
               (cdr entry)
               library-key))
            (environment-frame value-environment))
       (map (lambda (entry)
              (make-library-binding
               (car entry)
               'syntax
               (cdr entry)
               library-key))
            (syntax-environment-frame syntax-environment))))

    (define (register-scheme-base-library! context environment)
      "Register `(scheme base)' from the active or freshly built base state."
      (if (not (library-registry-ref context scheme-base-library-key))
          (let* ((use-current-environment?
                  (environment-cell environment '+))
                 (base-environment
                  (if use-current-environment?
                      environment
                      (consent-make-base-environment)))
                 (base-context
                  (if use-current-environment?
                      context
                      (new-eval-context '()))))
            (if (not use-current-environment?)
                (ensure-base-syntax! base-context base-environment))
            (let* ((base-syntax-environment
                    (context-syntax-environment base-context))
                   (exports
                    (snapshot-library-bindings
                     base-environment
                     base-syntax-environment
                     scheme-base-library-key)))
              (library-registry-set!
               context
               scheme-base-library-key
               (make-library
                scheme-base-library-key
                scheme-base-library-key
                exports
                base-environment
                base-syntax-environment))))))

    (define (source-library-copy-seen-ref seen value)
      "Return VALUE's copy recorded in identity map SEEN."
      (consent-identity-map-ref seen value #f))

    (define (source-library-copy-seen-set! seen value copy)
      "Record COPY as VALUE's context-local realization in SEEN."
      (consent-identity-map-set! seen value copy))

    (define (source-library-datum-label-syntax? source)
      "Report whether SOURCE may contain R7RS shared-datum label syntax."
      ;; Matches inside comments or strings only choose the conservative path;
      ;; every real datum label is still detected.
      (let ((state 0)
            (found? #f))
        (string-for-each
         (lambda (character)
           (if (not found?)
               (cond
                ((= state 0)
                 (if (char=? character #\#) (set! state 1)))
                ((= state 1)
                 (cond
                  ((char<=? #\0 character #\9) (set! state 2))
                  ((not (char=? character #\#)) (set! state 0))))
                ((char<=? #\0 character #\9))
                ((or (char=? character #\=)
                     (char=? character #\#))
                 (set! found? #t))
                (else
                 (set! state (if (char=? character #\#) 1 0))))))
         source)
        found?))

    (define (source-library-copy-source! copy source context)
      "Record COPY's canonical SOURCE in CONTEXT-local provenance."
      (context-source-copy-set-fresh! context copy source))

    (define (source-library-copy-tree value context)
      "Copy acyclic mutable VALUE while preserving default-domain symbols."
      (cond
       ((or (consent-symbol? value) (host-symbol? value)) value)
       ((pair? value)
        (let ((copy
               (cons (source-library-copy-tree (car value) context)
                     (source-library-copy-tree (cdr value) context))))
          (source-library-copy-source! copy value context)))
       ((string? value)
        (source-library-copy-source! (string-copy value) value context))
       ((bytevector? value)
        (source-library-copy-source! (bytevector-copy value) value context))
       ((vector? value)
        (let ((copy (make-vector (vector-length value) #f)))
          (let loop ((index 0))
            (if (< index (vector-length value))
                (begin
                  (vector-set!
                   copy
                   index
                   (source-library-copy-tree
                    (vector-ref value index)
                    context))
                  (loop (+ index 1)))))
          (source-library-copy-source! copy value context)))
       (else value)))

    (define (source-library-copy-datum value seen context)
      "Copy mutable VALUE while preserving sharing and default symbols."
      (cond
       ((or (consent-symbol? value) (host-symbol? value)) value)
       ((pair? value)
        (or (source-library-copy-seen-ref seen value)
            (let ((copy (cons #f #f)))
              (source-library-copy-seen-set! seen value copy)
              (set-car!
               copy
               (source-library-copy-datum (car value) seen context))
              (set-cdr!
               copy
               (source-library-copy-datum (cdr value) seen context))
              (source-library-copy-source! copy value context))))
       ((string? value)
        (or (source-library-copy-seen-ref seen value)
            (let ((copy (string-copy value)))
              (source-library-copy-seen-set! seen value copy)
              (source-library-copy-source! copy value context))))
       ((bytevector? value)
        (or (source-library-copy-seen-ref seen value)
            (let ((copy (bytevector-copy value)))
              (source-library-copy-seen-set! seen value copy)
              (source-library-copy-source! copy value context))))
       ((vector? value)
        (or (source-library-copy-seen-ref seen value)
            (let ((copy (make-vector (vector-length value) #f)))
              (source-library-copy-seen-set! seen value copy)
              (let loop ((index 0))
                (if (< index (vector-length value))
                    (begin
                      (vector-set!
                       copy
                       index
                       (source-library-copy-datum
                        (vector-ref value index)
                        seen
                        context))
                      (loop (+ index 1)))))
              (source-library-copy-source! copy value context))))
       (else value)))

    (define (source-library-copy-forms forms shared-datum? context)
      "Return CONTEXT-owned mutable copies of canonical source FORMS."
      ;; Custom symbol tables parse afresh and never reach this helper.
      (if shared-datum?
          (if (consent-identity-map-fast-backend?)
              (source-library-copy-datum
               forms (consent-make-identity-map) context)
              ;; Manifest realization reparses shared syntax on the portable
              ;; compatibility backend. Keep this guard so no future caller
              ;; silently routes an ultra-critical graph copy through the
              ;; adapter's identity-alist fallback.
              (eval-error
               "shared source copy requires a fast identity-map backend"))
          (source-library-copy-tree forms context)))

    (define (manifest-source-library-forms
             source context preserve-source?)
      "Return parsed SOURCE forms in CONTEXT's symbol domain."
      "The default symbol domain caches canonical syntax, then copies its"
      "mutable graph into each context. Custom symbol domains parse afresh."
      "Trusted immutable-data realizations parse without provenance because"
      "their evaluated data instance, rather than source syntax, is cached."
      (if (not preserve-source?)
          (consent-read-all
           source
           (cons
            (cons 'source-metadata #f)
            (context-reader-options context)))
          (if (host-eq? (context-symbol-table context)
                        consent-default-symbol-table)
              (let* ((cached
                      (assoc/equal source manifest-source-library-form-cache))
                     (uncached-shared-datum?
                      (and
                       (not cached)
                       (source-library-datum-label-syntax? source))))
                (if (and uncached-shared-datum?
                         (not (consent-identity-map-fast-backend?)))
                    ;; The compatibility identity map is intentionally an
                    ;; association list. Reparse rare labelled sources into the
                    ;; caller's context instead of turning graph realization
                    ;; quadratic on a host without identity hashing.
                    (consent-read-all source (context-reader-options context))
                    (let* ((forms
                            (if cached
                                (cadr cached)
                                (let ((parsed
                                       (consent-read-all
                                        source
                                        ;; Canonical syntax intentionally lives
                                        ;; in this process cache. Keep its
                                        ;; provenance in the matching
                                        ;; compatibility index rather than a
                                        ;; first caller's short-lived context.
                                        (cons
                                         (cons 'source-metadata-sink #f)
                                         (context-reader-options context)))))
                                  (set! manifest-source-library-form-cache
                                        (cons
                                         (list
                                          source
                                          parsed
                                          uncached-shared-datum?)
                                         manifest-source-library-form-cache))
                                  parsed)))
                           (shared-datum?
                            (if cached
                                (third cached)
                                uncached-shared-datum?)))
                      (source-library-copy-forms
                       forms shared-datum? context))))
              (consent-read-all source (context-reader-options context)))))

    (define (shared-immutable-source-library-entry? entry)
      "Report whether ENTRY explicitly declares immutable shared data."
      ;; This is a trusted repository-manifest assertion, not an inferred
      ;; property. Reviewers must verify that no mutable aggregate or
      ;; context-sensitive state crosses the library's export boundary.
      (and
       (source-library-internal-imports-allowed?)
       (library-symbol-eq?
        (collection-entry-field entry 'realization #f)
        'shared-immutable-data)
       (library-symbol-eq?
        (collection-entry-field entry 'visibility #f)
        'internal-runtime)
       (library-symbol-eq?
        (collection-entry-field entry 'source-kind #f)
        'portable-source)
       (not
        (collection-entry-field
         entry 'primitive-overlay-library #f))))

    (define (shared-immutable-source-library-key entry context)
      "Return ENTRY's process-cache key in CONTEXT, or #f."
      (if (and
           (shared-immutable-source-library-entry? entry)
           (host-eq? (context-symbol-table context)
                     consent-default-symbol-table))
          (list
           (collection-entry-field entry 'name #f)
           (collection-entry-field entry 'root #f)
           (collection-entry-field entry 'source-file #f)
           (collection-entry-field entry 'source-kind #f)
           (collection-entry-field entry 'source-version #f)
           (collection-entry-field entry 'realization #f)
           (collection-entry-field entry 'visibility #f)
           (collection-entry-field entry 'exports-declared? #f)
           (collection-entry-field entry 'exports '())
           (collection-entry-field entry 'primitive-overlay-library #f)
           (consent-library-search-directory-list))
          #f))

    (define (shared-immutable-source-library-ref cache-key)
      "Return the immutable library cache entry under CACHE-KEY, or #f."
      (let ((entry
             (and cache-key
                  (assoc/equal cache-key
                               shared-immutable-source-library-cache))))
        (and entry (cdr entry))))

    (define (shared-immutable-source-library-set!
             cache-key library step-cost value-node-cost)
      "Cache immutable source LIBRARY and its logical costs under CACHE-KEY."
      (if cache-key
          (set! shared-immutable-source-library-cache
                (cons (list
                       cache-key library step-cost value-node-cost)
                      shared-immutable-source-library-cache)))
      consent-unspecified)

    (define (shared-immutable-source-library-charge-costs!
             context step-cost value-node-cost)
      "Charge CONTEXT the aggregate logical costs of a cached source library."
      ;; Evaluation budgets are observable in result records. The process
      ;; cache avoids host work, but cannot make that logical cost depend on
      ;; whether another context happened to load the library first. Replay
      ;; preserves each aggregate dimension, not the cold evaluation's
      ;; chronological interleaving between dimensions.
      (let loop ((remaining step-cost))
        (if (> remaining 0)
            (begin
              (note-step! context)
              (loop (- remaining 1)))))
      (note-value-allocation! context value-node-cost))

    (define (register-source-library!
             source context environment preserve-source?)
      "Read and evaluate a define-library form from SOURCE."
      (dynamic-wind
        (lambda ()
          (set! source-library-internal-import-depth
                (+ source-library-internal-import-depth 1)))
        (lambda ()
          (let ((forms
                 (manifest-source-library-forms
                  source context preserve-source?)))
            (if (not (= (length forms) 1))
                (eval-error "source library must contain exactly one form"))
            (eval-define-library
             (car forms)
             environment
             context)))
        (lambda ()
          (set! source-library-internal-import-depth
                (- source-library-internal-import-depth 1)))))

    (define (native-number-or-owned value)
      "Return VALUE's bounded host scalar, preserving owned numeric storage"
      "when the bootstrap adapter cannot represent it."
      (guard (condition (else value))
        (let ((host (consent-number-value value)))
          (if (number? host) host value))))

    (define (native-egress-container? value)
      "Report whether VALUE is a host or owned traversable container."
      (or (pair? value)
          (vector? value)
          (consent-datum-object? value)))

    (define (native-egress-authorize-any! value)
      "Permit VALUE to enter an explicitly audited native conversion."
      #t)

    (define (native-egress-reject-borrow! value)
      "Reject VALUE before an unclassified native binding can borrow it."
      (if (or (consent-datum-object? value)
              (native-interpreted-callable? value))
          (error
           "native-binding-borrow-unavailable: binding is not allowlisted"))
      #t)

    ;; One owned-state box supplies the sole intrusive-map token for an outer
    ;; native operation. Each object maps to
    ;; #(bridge-entry completed-target walk-generation walk-node), fusing the
    ;; bridge index, cross-root egress cache, and current-walk index that used
    ;; to overlap as three independent maps.
    (define (make-native-owned-state)
      "Return a lazy box for one outer operation's owned-object map."
      (vector #f))

    (define (native-owned-state-map state create?)
      "Return STATE's owned-object map, optionally allocating it."
      (or (vector-ref state 0)
          (and create?
               (let ((created (consent-make-datum-object-map)))
                 (vector-set! state 0 created)
                 created))))

    (define (native-owned-object-state-ref state source absent)
      "Return SOURCE's composite native state, or ABSENT."
      (let ((map (native-owned-state-map state #f)))
        (if map
            (consent-datum-object-map-ref map source absent)
            absent)))

    (define (native-owned-object-state! state source)
      "Return SOURCE's existing or fresh composite native state."
      (let* ((absent (vector 'native-owned-object-state-absent))
             (known (native-owned-object-state-ref state source absent)))
        (if (eq? known absent)
            (let ((created (vector #f #f #f #f)))
              (consent-datum-object-map-set!
               (native-owned-state-map state #t) source created)
              created)
            known)))

    (define (native-owned-state-release! state)
      "Release STATE's intrusive owned-object map when allocated."
      (let ((map (native-owned-state-map state #f)))
        (if map (consent-datum-object-map-release! map)))
      state)

    (define (make-native-egress-state owned-state)
      "Return cross-root host conversion state sharing OWNED-STATE."
      (vector #f owned-state))

    (define (call-with-fresh-native-egress-state procedure)
      "Call PROCEDURE with fresh egress state and release it on every exit."
      (let* ((owned-state (make-native-owned-state))
             (state (make-native-egress-state owned-state)))
        (dynamic-wind
         (lambda () #t)
         (lambda () (procedure state))
         (lambda () (native-owned-state-release! owned-state)))))

    (define (native-egress-state-ref state source absent)
      "Return SOURCE's completed conversion from STATE, or ABSENT."
      (if (consent-datum-object? source)
          (let* ((owned-state (vector-ref state 1))
                 (object-state
                  (native-owned-object-state-ref
                   owned-state source absent)))
            (if (eq? object-state absent)
                absent
                (or (vector-ref object-state 1) absent)))
          (let ((map (vector-ref state 0)))
            (if map
                (consent-identity-map-ref map source absent)
                absent))))

    (define (native-egress-state-set! state source target)
      "Memoize SOURCE's completed conversion as TARGET in STATE."
      (if (consent-datum-object? source)
          (vector-set!
           (native-owned-object-state! (vector-ref state 1) source)
           1
           target)
          (let ((map (vector-ref state 0)))
            (if (not map)
                (begin
                  (require-native-fast-identity-maps!)
                  (set! map (consent-make-identity-map))
                  (vector-set! state 0 map)))
            (consent-identity-map-set! map source target)))
      target)

    (define (native-egress-graph
             value
             state
             leaf
             copy-host-source
             reuse-owned
             allocate-owned
             finish-owned
             authorize)
      "Convert one mixed host/owned graph iteratively in expected O(V+E)."
      "Host pairs/vectors use copy-on-change. Owned containers always project"
      "to host shells unless REUSE-OWNED returns an existing mirror. Shells"
      "are allocated for the full dirty graph before any edge is initialized,"
      "so mixed-domain cycles and sharing never recurse through LEAF."
      (authorize value)
      (if (not (native-egress-container? value))
          (leaf value)
          (let ((absent (vector 'native-egress-absent)))
            (let ((cached
                   (native-egress-state-ref state value absent)))
              (if (not (eq? cached absent))
                  cached
                  (let ((host-nodes #f)
                        (walk-generation
                         (vector 'native-egress-walk-generation))
                        (nodes '())
                        (scan-work '())
                        (dirty-work '()))
                    (define (local-node-ref source)
                      "Return SOURCE's current-walk node, or #f."
                      "A node is #(source owned? kind edges parents dirty? copy"
                      "reused?). A compound edge points to a local node; a"
                      "fixed edge carries a converted leaf or prior result."
                      (if (consent-datum-object? source)
                          (let* ((owned-state (vector-ref state 1))
                                 (object-state
                                  (native-owned-object-state-ref
                                   owned-state source #f)))
                            (and object-state
                                 (eq? (vector-ref object-state 2)
                                      walk-generation)
                                 (vector-ref object-state 3)))
                          (and
                           host-nodes
                           (consent-identity-map-ref
                            host-nodes source #f))))
                    (define (local-node-set! source node)
                      "Index SOURCE as NODE in the current walk."
                      (if (consent-datum-object? source)
                          (let ((object-state
                                 (native-owned-object-state!
                                  (vector-ref state 1) source)))
                            (vector-set!
                             object-state 2 walk-generation)
                            (vector-set! object-state 3 node))
                          (begin
                            (if (not host-nodes)
                                (begin
                                  (require-native-fast-identity-maps!)
                                  (set! host-nodes
                                        (consent-make-identity-map))))
                            (consent-identity-map-set!
                             host-nodes source node))))
                    (define (source-kind source owned?)
                      "Return SOURCE's compound kind."
                      (if owned?
                          (consent-datum-object-kind source)
                          (if (pair? source) 'pair 'vector)))
                    (define (source-length source owned? kind)
                      "Return SOURCE's traversable outgoing-edge count."
                      (case kind
                        ((pair) 2)
                        ((vector)
                         (if owned?
                             (consent-datum-vector-length source)
                             (vector-length source)))
                        (else 0)))
                    (define (mark-dirty! node)
                      "Mark NODE changed and schedule one parent propagation."
                      (if (not (vector-ref node 5))
                          (begin
                            (vector-set! node 5 #t)
                            (set! dirty-work (cons node dirty-work)))))
                    (define (make-node source)
                      "Allocate and index one current-walk graph node."
                      (let* ((owned? (consent-datum-object? source))
                             (kind (source-kind source owned?))
                             (candidate
                              (if owned?
                                  (reuse-owned source absent)
                                  absent))
                             (reused? (not (eq? candidate absent)))
                             (length
                              (if reused?
                                  0
                                  (source-length source owned? kind)))
                             (node
                              (vector source
                                      owned?
                                      kind
                                      (make-vector length #f)
                                      '()
                                      #f
                                      (if reused? candidate #f)
                                      reused?)))
                        (local-node-set! source node)
                        (set! nodes (cons node nodes))
                        (if owned? (mark-dirty! node))
                        (if (> length 0)
                            (set! scan-work (cons node scan-work)))
                        node))
                    (define (node-for source)
                      "Return SOURCE's current-walk node, allocating it once."
                      (or (local-node-ref source) (make-node source)))
                    (define (source-edge node index)
                      "Return NODE's source child at logical edge INDEX."
                      (let ((source (vector-ref node 0))
                            (owned? (vector-ref node 1)))
                        (case (vector-ref node 2)
                          ((pair)
                           (if owned?
                               (if (= index 0)
                                   (consent-datum-car source)
                                   (consent-datum-cdr source))
                               (if (= index 0)
                                   (car source)
                                   (cdr source))))
                          ((vector)
                           (if owned?
                               (consent-datum-vector-ref source index)
                               (vector-ref source index))))))
                    (define (fixed-edge! node index source converted)
                      "Store one converted fixed edge and mark changes."
                      (vector-set!
                       (vector-ref node 3)
                       index
                       (vector #f converted source))
                      (if (not
                           (native-slot-value-same? converted source))
                          (mark-dirty! node)))
                    (define (scan-edge! node index source)
                      "Record one SOURCE edge without recursive descent."
                      (authorize source)
                      (if (native-egress-container? source)
                          (let ((prior
                                 (native-egress-state-ref
                                  state source absent)))
                            (if (not (eq? prior absent))
                                (fixed-edge! node index source prior)
                                (let ((child (node-for source)))
                                  (vector-set!
                                   (vector-ref node 3)
                                   index
                                   (vector #t child #f))
                                  (vector-set!
                                   child
                                   4
                                   (cons node (vector-ref child 4))))))
                          (fixed-edge! node index source (leaf source))))
                    (define (allocate-copy! node)
                      "Allocate NODE's selected target shell."
                      (if (not (vector-ref node 7))
                          (let* ((source (vector-ref node 0))
                                 (owned? (vector-ref node 1))
                                 (kind (vector-ref node 2))
                                 (copy
                                  (case kind
                                    ((pair) (cons #f #f))
                                    ((string)
                                     (consent-datum-string->host source))
                                    ((bytevector)
                                     (consent-datum-bytevector->host source))
                                    ((vector)
                                     (make-vector
                                      (source-length
                                       source owned? kind)
                                      #f))
                                    (else
                                     (error
                                      "native egress: unsupported datum kind"
                                      kind)))))
                            (vector-set! node 6 copy)
                            (if owned?
                                (allocate-owned copy source)))))
                    (define (edge-result edge)
                      "Return EDGE's converted fixed value or child target."
                      (if (vector-ref edge 0)
                          (let ((child (vector-ref edge 1)))
                            (if (vector-ref child 5)
                                (vector-ref child 6)
                                (vector-ref child 0)))
                          (vector-ref edge 1)))
                    (define (fill-copy! node)
                      "Initialize NODE and finalize provenance or snapshots."
                      (if (not (vector-ref node 7))
                          (let ((source (vector-ref node 0))
                                (owned? (vector-ref node 1))
                                (kind (vector-ref node 2))
                                (edges (vector-ref node 3))
                                (copy (vector-ref node 6)))
                            (case kind
                              ((pair)
                               (set-car!
                                copy
                                (edge-result (vector-ref edges 0)))
                               (set-cdr!
                                copy
                                (edge-result (vector-ref edges 1))))
                              ((vector)
                               (let loop ((index 0))
                                 (if (< index (vector-length edges))
                                     (begin
                                       (vector-set!
                                        copy
                                        index
                                        (edge-result
                                         (vector-ref edges index)))
                                       (loop (+ index 1)))))))
                            (if owned?
                                (finish-owned copy source)
                                (copy-host-source copy source)))))
                    (let ((root (make-node value)))
                      (let scan ()
                        (if (pair? scan-work)
                            (let* ((node (car scan-work))
                                   (length
                                    (vector-length (vector-ref node 3))))
                              (set! scan-work (cdr scan-work))
                              (let edge-loop ((index 0))
                                (if (< index length)
                                    (begin
                                      (scan-edge!
                                       node index (source-edge node index))
                                      (edge-loop (+ index 1)))))
                              (scan))))
                      (let propagate ()
                        (if (pair? dirty-work)
                            (let ((node (car dirty-work)))
                              (set! dirty-work (cdr dirty-work))
                              (let parent-loop
                                  ((parents (vector-ref node 4)))
                                (if (pair? parents)
                                    (begin
                                      (mark-dirty! (car parents))
                                      (parent-loop (cdr parents)))))
                              (propagate))))
                      ;; All dirty shells exist before any outgoing edge is
                      ;; written, which closes arbitrary mixed-domain cycles.
                      (let allocate ((rest nodes))
                        (if (pair? rest)
                            (begin
                              (if (vector-ref (car rest) 5)
                                  (allocate-copy! (car rest)))
                              (allocate (cdr rest)))))
                      (let fill ((rest nodes))
                        (if (pair? rest)
                            (begin
                              (if (vector-ref (car rest) 5)
                                  (fill-copy! (car rest)))
                              (fill (cdr rest)))))
                      (let remember ((rest nodes))
                        (if (pair? rest)
                            (let ((node (car rest)))
                              (native-egress-state-set!
                               state
                               (vector-ref node 0)
                               (if (vector-ref node 5)
                                   (vector-ref node 6)
                                   (vector-ref node 0)))
                              (remember (cdr rest)))))
                      (if (vector-ref root 5)
                          (vector-ref root 6)
                          value))))))))

    (define (native-copy-source-noop! target source)
      "Return TARGET without attaching durable source metadata."
      target)

    (define (native-owned-reuse-none source absent)
      "Decline owned SOURCE reuse by returning ABSENT."
      absent)

    (define (native-owned-allocation-noop! target source)
      "Return TARGET without registering a call-scoped mirror."
      target)

    (define (native-callback-result value convert-symbols?)
      "Convert an interpreted callback's result for native consumption."
      "Owned characters become host characters, and canonical number records"
      "become bounded host numbers -- a custom resync"
      "strategy returns an offset the reader clamps with host arithmetic --"
      "while values outside the adapter range keep their owned representation.\
"
      "The interpreter's end-of-file record becomes the host end-of-file"
      "object a native input driver tests with eof-object?. Owned symbols are"
      "converted only for native libraries that inspect their callback result;\
"
      "higher-order host controls such as `call-with-input-file' return callba\
ck"
      "results opaquely and preserve their Consent symbol identity instead."
      "One mixed-domain worklist preserves host/owned cycles and sharing."
      (let ((bridge native-call-graph-bridge))
        (define (convert state)
          (native-egress-graph
           value
           state
           (lambda (leaf)
             (cond
              ((and convert-symbols? (consent-symbol? leaf))
               (host-string->symbol (consent-symbol-name leaf)))
              ((consent-character? leaf)
               (consent-character->host-character leaf))
              ((consent-number? leaf) (native-number-or-owned leaf))
              ((consent-eof-object? leaf) (eof-object))
              (else leaf)))
           native-copy-source-noop!
           (if bridge
               (lambda (owned absent)
                 (native-bridge-owned-reuse bridge owned absent))
               native-owned-reuse-none)
           (if bridge
               (lambda (native owned)
                 (native-bridge-allocate-owned! bridge owned native))
               native-owned-allocation-noop!)
           (if bridge
               (lambda (native owned)
                 (native-bridge-finish-owned! bridge owned native))
               native-copy-source-noop!)
           native-egress-authorize-any!))
        (if bridge
            (convert (ensure-native-bridge-egress-state! bridge))
            (call-with-fresh-native-egress-state convert))))

    (define (native-runtime-datum-result value)
      "Convert runtime VALUE to host data with linear, stack-safe graph walks."
      (call-with-fresh-native-egress-state
       (lambda (state)
         (native-egress-graph
          value
          state
          (lambda (leaf)
            (cond
             ((consent-symbol? leaf)
              (host-string->symbol (consent-symbol-name leaf)))
             ((consent-character? leaf)
              (consent-character->host-character leaf))
             ((consent-number? leaf) (native-number-or-owned leaf))
             ((consent-eof-object? leaf) (eof-object))
             (else leaf)))
          native-copy-source-noop!
          native-owned-reuse-none
          native-owned-allocation-noop!
          native-copy-source-noop!
          native-egress-authorize-any!))))

    (define (consent-runtime-datum->native-datum value)
      "Convert runtime VALUE to ordinary host-facing Scheme data."
      "This is the context-free egress half of the native-call bridge. It is"
      "used for public result datums that contain no live evaluator callbacks.\
"
      "Source provenance stays with the owned graph; the returned host copy"
      "must not become a process-lifetime metadata root."
      #((parameters
         (value (type object)
          (description "Runtime datum about to return to native code.")))
        (returns (type object)
         (description
          ("VALUE with owned symbols, characters, canonical numbers, and EOF"
            "records converted to their ordinary host representations.")))
        (effects pure allocation))
      (native-runtime-datum-result value))

    (define (native-callback-origin procedure)
      "Return PROCEDURE's same-call interpreted callback origin, or #f."
      (and
       native-call-graph-bridge
       (let ((index
              (native-bridge-callback-origin-index
               native-call-graph-bridge)))
         (and
          index
          (consent-identity-map-ref index procedure #f)))))

    (define (native-callback-shim
             value context . maybe-convert-symbols?)
      "Wrap interpreted callable VALUE as a host procedure applying it in"
      "CONTEXT. Callback arguments re-enter the Consent world through the"
      "shared host-datum bridge, so interpreted callbacks see canonical"
      "Consent numbers and preserved source-metadata structure instead of raw \
host"
      "runtime values leaking through the compiled boundary."
      "The closure's result crosses back under the callback result conversion"
      "(canonical records become raw host numbers), so native higher-order"
      "code can consume what the closure returns."
      (let* ((convert-symbols?
              (and (pair? maybe-convert-symbols?)
                   (car maybe-convert-symbols?)))
             (bridge (current-native-graph-bridge context))
             (scope (and bridge (native-bridge-scope bridge)))
             (cached
              (and bridge
                   (native-bridge-callback-shim-ref
                    bridge value context convert-symbols?))))
        (or
         cached
         (let* ((applier (consent-native-applier-ref))
                (shim
                 (lambda arguments
                   (let ((active (current-native-graph-bridge context)))
                     (if (and scope
                              (or (not active)
                                  (not (host-eq?
                                        scope
                                        (native-bridge-scope active)))))
                         (error
                          "native callback shim escaped its call scope"))
                     (if active
                         (call-with-native-scalar-only-bridge
                          active
                          'callback
                          (lambda ()
                            (let* ((callback-arguments
                                    (native-bridge-native-values->owned
                                     active arguments))
                                   (result
                                    (applier
                                     value callback-arguments context)))
                              (apply
                               values
                               (map
                                (lambda (item)
                                  (native-bridge-owned->native
                                   active item convert-symbols?))
                                (values-list result))))))
                         (let* ((callback-arguments
                                 (map
                                  (lambda (argument)
                                    (native-result-value argument context))
                                  arguments))
                                (result
                                 (applier
                                  value callback-arguments context)))
                           (apply
                            values
                            (map
                             (lambda (item)
                               (native-callback-result
                                item convert-symbols?))
                             (values-list result)))))))))
           (if bridge
               (native-bridge-record-callback-shim!
                bridge value context convert-symbols? shim))
           shim))))

    ;; Context of the native call currently crossing the import boundary.
    ;; The native binding shim maintains it dynamically so callable arguments
    ;; applied by native higher-order code run in the calling program's
    ;; context.
    (define native-call-context #f)

    ;; The active native graph bridge is dynamically scoped with the outermost
    ;; native call. Re-entrant calls and callbacks share that one transaction;
    ;; its identity maps and callback shims become unreachable on outer unwind.
    ;; Raw host mirrors and callback shims must not escape or be retained by a
    ;; native library. Stateful native code retains Consent-owned values or
    ;; opaque handles, never borrowed host containers.
    (define native-call-graph-bridge #f)

    (define (require-native-fast-identity-maps!)
      "Reject native borrowing without the host identity-hash backend."
      (if (not (consent-identity-map-fast-backend?))
          (error
           "native-borrowing-unavailable: fast identity maps are required")))

    (define (make-native-graph-bridge context)
      "Return a fresh outer-call graph bridge for CONTEXT."
      ;; Slots zero and one are the context and scan list. Slot two is the
      ;; fused lazy owned-object state; slot three lazily indexes native
      ;; identity. Slot four lazily
      ;; holds call-scoped callback indexes; slot five is the unique scope
      ;; token. Slot six records a dynamically scoped compound-entry
      ;; prohibition for callbacks or re-entrant native transitions. Slot
      ;; seven lazily memoizes mixed-domain egress across argument roots.
      ;; The portable alist backend preserves identity semantics but would make
      ;; graph and callback transitions silently quadratic. Native borrowing
      ;; is therefore unavailable unless the host provides identity hashing.
      (require-native-fast-identity-maps!)
      (vector context
              '()
              (make-native-owned-state)
              #f
              #f
              (list 'native-call-scope)
              #f
              #f))

    (define (native-bridge-context bridge)
      "Return BRIDGE's owning evaluation context."
      (vector-ref bridge 0))

    (define (set-native-bridge-context! bridge context)
      "Update BRIDGE to use the active evaluation CONTEXT."
      (vector-set! bridge 0 context))

    (define (native-bridge-entries bridge)
      "Return BRIDGE's owned/native mapping entries."
      (vector-ref bridge 1))

    (define (set-native-bridge-entries! bridge entries)
      "Replace BRIDGE's owned/native mapping ENTRIES."
      (vector-set! bridge 1 entries))

    (define (ensure-native-bridge-egress-state! bridge)
      "Return BRIDGE's call-scoped mixed-domain egress state."
      (or (vector-ref bridge 7)
          (let ((created
                 (make-native-egress-state
                  (native-bridge-owned-index bridge))))
            (vector-set! bridge 7 created)
            created)))

    (define (native-bridge-owned-index bridge)
      "Return BRIDGE's fused lazy owned-object state."
      (vector-ref bridge 2))

    (define (ensure-native-bridge-owned-index! bridge)
      "Return BRIDGE's fused lazy owned-object state."
      (native-bridge-owned-index bridge))

    (define (native-bridge-native-index bridge)
      "Return BRIDGE's native-object identity index, or #f when unallocated."
      (vector-ref bridge 3))

    (define (ensure-native-bridge-native-index! bridge)
      "Return BRIDGE's native-object identity index, allocating it lazily."
      (or (native-bridge-native-index bridge)
          (let ((created (consent-make-identity-map)))
            (vector-set! bridge 3 created)
            created)))

    (define (native-bridge-callback-indexes bridge)
      "Return BRIDGE's callback identity indexes, or #f when unallocated."
      (vector-ref bridge 4))

    (define (ensure-native-bridge-callback-indexes! bridge)
      "Return BRIDGE's callback identity indexes, allocating them lazily."
      (or (native-bridge-callback-indexes bridge)
          (let ((created
                 (vector (consent-make-identity-map)
                         (consent-make-identity-map))))
            (vector-set! bridge 4 created)
            created)))

    (define (native-bridge-callback-forward-index bridge)
      "Return BRIDGE's forward callback index, or #f when unallocated."
      (let ((indexes (native-bridge-callback-indexes bridge)))
        (and indexes (vector-ref indexes 0))))

    (define (native-bridge-callback-origin-index bridge)
      "Return BRIDGE's reverse callback index, or #f when unallocated."
      (let ((indexes (native-bridge-callback-indexes bridge)))
        (and indexes (vector-ref indexes 1))))

    (define (native-bridge-callback-shim-ref
             bridge callable context convert-symbols?)
      "Return BRIDGE's shim for one callable/context/policy key, or #f."
      (let* ((forward (native-bridge-callback-forward-index bridge))
             (policies
              (and
               forward
               (consent-identity-map-ref forward context #f))))
        (and
         policies
         (let ((callables
                (consent-identity-map-ref
                 policies convert-symbols? #f)))
           (and
            callables
            (consent-identity-map-ref
             callables callable #f))))))

    (define (native-bridge-record-callback-shim!
             bridge callable context convert-symbols? shim)
      "Index SHIM by its host-identity callback key and reverse origin."
      (let* ((indexes
              (ensure-native-bridge-callback-indexes! bridge))
             (forward (vector-ref indexes 0))
             (policies
              (or
               (consent-identity-map-ref forward context #f)
               (let ((created (consent-make-identity-map)))
                 (consent-identity-map-set! forward context created)
                 created)))
             (callables
              (or
               (consent-identity-map-ref
                policies convert-symbols? #f)
               (let ((created (consent-make-identity-map)))
                 (consent-identity-map-set!
                  policies convert-symbols? created)
                 created))))
        (consent-identity-map-set!
         callables callable shim)
        (consent-identity-map-set!
         (vector-ref indexes 1) shim callable)
        shim))

    (define (native-bridge-scope bridge)
      "Return BRIDGE's unique outer-call scope token."
      (vector-ref bridge 5))

    (define (native-bridge-compound-prohibition bridge)
      "Return BRIDGE's active compound-entry prohibition, or #f."
      (vector-ref bridge 6))

    (define (set-native-bridge-compound-prohibition! bridge reason)
      "Set BRIDGE's compound-entry prohibition to REASON or #f."
      (vector-set! bridge 6 reason))

    (define (native-bridge-reject-compound! reason)
      "Raise the fail-closed compound-transition error for REASON."
      (error
       (case reason
         ((callback)
          "native-compound-callback-unavailable: scalar values required")
         ((reentrant)
          "native-compound-reentry-unavailable: scalar values required")
         (else
          "native-compound-transition-unavailable: scalar values required"))))

    (define (call-with-native-scalar-only-bridge bridge reason thunk)
      "Call THUNK while BRIDGE rejects compound entries for nested REASON."
      (if (pair? (native-bridge-entries bridge))
          (native-bridge-reject-compound! reason))
      (let ((previous
             (native-bridge-compound-prohibition bridge)))
        (dynamic-wind
         (lambda ()
           (set-native-bridge-compound-prohibition! bridge reason))
         thunk
         (lambda ()
           (set-native-bridge-compound-prohibition! bridge previous)))))

    (define (current-native-graph-bridge context)
      "Return the active graph bridge when it belongs to CONTEXT's heap."
      (and native-call-graph-bridge
           (host-eq?
            (context-datum-heap context)
            (context-datum-heap
             (native-bridge-context native-call-graph-bridge)))
           native-call-graph-bridge))

    ;; A mapping entry is `#(owned native kind snapshot)'. SNAPSHOT records the
    ;; native object's last synchronized contents, so finalization can
    ;; distinguish replacement of a referent from mutation inside that
    ;; referent.
    (define (native-bridge-owned-entry bridge value)
      "Return BRIDGE's entry for owned VALUE, or #f."
      (and
       (consent-datum-object? value)
       (let ((object-state
              (native-owned-object-state-ref
               (native-bridge-owned-index bridge) value #f)))
         (and object-state (vector-ref object-state 0)))))

    (define (native-bridge-native-entry bridge value)
      "Return BRIDGE's entry for host VALUE, or #f."
      (let ((index (native-bridge-native-index bridge)))
        (and index (consent-identity-map-ref index value #f))))

    (define (native-vector-snapshot vector)
      "Return a shallow identity snapshot of host VECTOR."
      (let* ((length (vector-length vector))
             (snapshot (make-vector length #f)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (vector-set! snapshot index (vector-ref vector index))
                (loop (+ index 1)))))
        snapshot))

    (define (native-string-snapshot string)
      "Return a character-vector snapshot of host STRING in one traversal."
      ;; R7RS permits variable-width host strings whose indexed access is not
      ;; constant time. Traverse once, then use O(1) vector indexing during
      ;; reconciliation.
      (let ((snapshot (make-vector (string-length string) #f))
            (index 0))
        (string-for-each
         (lambda (character)
           (vector-set! snapshot index character)
           (set! index (+ index 1)))
         string)
        snapshot))

    (define (native-bytevector-snapshot bytevector)
      "Return a byte-for-byte copy of host BYTEVECTOR."
      (let* ((length (bytevector-length bytevector))
             (snapshot (make-bytevector length 0)))
        (let loop ((index 0))
          (if (< index length)
              (begin
                (bytevector-u8-set!
                 snapshot index (bytevector-u8-ref bytevector index))
                (loop (+ index 1)))))
        snapshot))

    (define (native-bridge-snapshot kind native)
      "Return the synchronization snapshot for native object KIND."
      (case kind
        ((pair) (vector (car native) (cdr native)))
        ((string) (native-string-snapshot native))
        ((vector) (native-vector-snapshot native))
        ((bytevector) (native-bytevector-snapshot native))
        (else #f)))

    (define (native-bridge-add-entry! bridge owned native)
      "Record the OWNED/NATIVE identity pair in BRIDGE and return its entry."
      (or (native-bridge-owned-entry bridge owned)
          (native-bridge-native-entry bridge native)
          (begin
            (if (native-bridge-compound-prohibition bridge)
                (native-bridge-reject-compound!
                 (native-bridge-compound-prohibition bridge)))
            (let* ((kind (consent-datum-object-kind owned))
                   (entry
                    (vector owned
                            native
                            kind
                            #f)))
              (set-native-bridge-entries!
               bridge
               (cons entry (native-bridge-entries bridge)))
              (vector-set!
               (native-owned-object-state!
                (ensure-native-bridge-owned-index! bridge) owned)
               0
               entry)
              (consent-identity-map-set!
               (ensure-native-bridge-native-index! bridge) native entry)
              entry))))

    (define (native-bridge-owned-reuse bridge owned absent)
      "Return OWNED's existing borrowed mirror in BRIDGE, or ABSENT."
      (let ((entry (native-bridge-owned-entry bridge owned)))
        (if entry (vector-ref entry 1) absent)))

    (define (native-bridge-allocate-owned! bridge owned native)
      "Register OWNED's shell before mixed graph edges are initialized."
      ;; Identity registration closes host-to-owned back edges without
      ;; recursive conversion. Snapshot only after all slots are initialized;
      ;; scanning a fresh vector/string/bytevector shell here would duplicate
      ;; the full O(N) snapshot immediately taken by FINISH-OWNED!.
      (native-bridge-add-entry! bridge owned native)
      native)

    (define (native-bridge-finish-owned! bridge owned native)
      "Snapshot OWNED's complete NATIVE mirror after edge initialization."
      (let ((entry (native-bridge-owned-entry bridge owned)))
        (if entry
            (vector-set!
             entry
             3
             (native-bridge-snapshot
              (consent-datum-object-kind owned) native))))
      native)

    (define (native-bridge-owned->native
             bridge value convert-symbols? . maybe-allow-borrow?)
      "Convert VALUE through one call-scoped mixed-domain graph worklist."
      (let ((authorize
             (if (or (null? maybe-allow-borrow?)
                     (car maybe-allow-borrow?))
                 native-egress-authorize-any!
                 native-egress-reject-borrow!)))
        (native-egress-graph
         value
         (ensure-native-bridge-egress-state! bridge)
         (lambda (item)
           (cond
            ((and convert-symbols? (consent-symbol? item))
             (host-string->symbol (consent-symbol-name item)))
            ((consent-character? item)
             (consent-character->host-character item))
            ((consent-number? item) (native-number-or-owned item))
            ((consent-eof-object? item) (eof-object))
            ((or (consent-procedure? item)
                 (consent-primitive-procedure? item)
                 (continuation? item)
                 (consent-parameter? item))
             (native-callback-shim
              item (native-bridge-context bridge) #t))
            (else item)))
         ;; Borrowed mirrors must not enter durable source metadata indexes;
         ;; all bridge state becomes unreachable when the outer call unwinds.
         native-copy-source-noop!
         (lambda (owned absent)
           (native-bridge-owned-reuse bridge owned absent))
         (lambda (native owned)
           (native-bridge-allocate-owned! bridge owned native))
         (lambda (native owned)
           (native-bridge-finish-owned! bridge owned native))
         authorize)))

    (define (native-slot-value-same? left right)
      "Report whether native slot values LEFT and RIGHT keep one referent."
      (cond
       ((and (number? left) (number? right)) (eqv? left right))
       ((and (char? left) (char? right)) (eqv? left right))
       (else (host-eq? left right))))

    (define (native-bridge-slot-specs entries)
      "Return changed pair/vector writeback slot specifications for ENTRIES."
      (let entry-loop ((rest entries) (specs '()))
        (if (null? rest)
            (reverse specs)
            (let* ((entry (car rest))
                   (native (vector-ref entry 1))
                   (kind (vector-ref entry 2))
                   (snapshot (vector-ref entry 3)))
              (if (not snapshot)
                  (entry-loop (cdr rest) specs)
                  (case kind
                ((pair)
                 (let* ((head (car native))
                        (previous-head (vector-ref snapshot 0))
                        (next-specs
                         (if (native-slot-value-same? head previous-head)
                             specs
                             (cons
                              (vector entry 0 head previous-head)
                              specs)))
                        (tail (cdr native))
                        (previous-tail (vector-ref snapshot 1)))
                   (entry-loop
                    (cdr rest)
                    (if (native-slot-value-same? tail previous-tail)
                        next-specs
                        (cons
                         (vector entry 1 tail previous-tail)
                         next-specs)))))
                ((vector)
                 (let vector-loop ((index 0) (next-specs specs))
                   (if (= index (vector-length native))
                       (entry-loop (cdr rest) next-specs)
                       (let ((current (vector-ref native index))
                             (previous (vector-ref snapshot index)))
                         (vector-loop
                          (+ index 1)
                          (if (native-slot-value-same? current previous)
                              next-specs
                              (cons
                               (vector entry index current previous)
                               next-specs)))))))
                (else (entry-loop (cdr rest) specs))))))))

    (define (native-bridge-sync-atomic-entry! bridge entry)
      "Copy native string or bytevector ENTRY mutations into its owned object."
      (let ((heap (context-datum-heap (native-bridge-context bridge)))
            (owned (vector-ref entry 0))
            (native (vector-ref entry 1))
            (kind (vector-ref entry 2))
            (snapshot (vector-ref entry 3)))
        (if snapshot
            (case kind
          ((string)
           (let ((index 0))
             (string-for-each
              (lambda (current)
                (if (not
                     (char=? current (vector-ref snapshot index)))
                    (begin
                      (consent-datum-string-set-host!
                       heap owned index current)
                      (vector-set! snapshot index current)))
                (set! index (+ index 1)))
              native)))
          ((bytevector)
           (let loop ((index 0))
             (if (< index (bytevector-length native))
                 (let ((current (bytevector-u8-ref native index)))
                   (if (not (= current
                               (bytevector-u8-ref snapshot index)))
                       (begin
                         (consent-datum-bytevector-u8-set!
                          heap owned index current)
                         (bytevector-u8-set!
                          snapshot index current)))
                   (loop (+ index 1))))))))))

    (define (native-bridge-register-imported!
             bridge target source root)
      "Register imported TARGET and return its fresh value-node cost."
      ;; ROOT is the temporary multi-value carrier. Known borrowed mirrors are
      ;; intercepted before allocation, so COPY-SOURCE sees fresh result or
      ;; condition nodes only. They receive provenance, never bridge entries
      ;; or mutation snapshots, and die normally with their owning context.
      (if (host-eq? source root)
          0
          (begin
            (context-copy-datum-source!
             (native-bridge-context bridge) target source #t)
            (native-imported-node-cost target))))

    (define (native-imported-node-cost target)
      "Return TARGET's exact freshly allocated value-node cost."
      ;; Match the source interpreter's constructor accounting: pairs charge
      ;; one shell, while vectors, strings, and bytevectors charge their shell
      ;; plus their freshly allocated slots or elements. Referenced child
      ;; values are charged only by the operation that creates those children.
      (case (consent-datum-object-kind target)
        ((pair) 1)
        ((vector)
         (+ 1 (consent-datum-vector-length-trusted target)))
        ((string)
         (+ 1 (consent-datum-string-length-trusted target)))
        ((bytevector)
         (+ 1 (consent-datum-bytevector-length target)))
        (else
         (error
          "native result import produced an unsupported compound"
          target))))

    (define (native-bridge-import-reuse bridge source absent)
      "Return SOURCE's already-owned bridge identity, or ABSENT."
      (let ((entry
             (and
              (or (pair? source)
                  (string? source)
                  (vector? source)
                  (bytevector? source))
              (native-bridge-native-entry bridge source))))
        (if entry (vector-ref entry 0) absent)))

    (define (native-bridge-apply-slot! bridge spec value)
      "Apply converted VALUE to one changed native slot SPEC."
      (let* ((entry (vector-ref spec 0))
             (slot (vector-ref spec 1))
             (current (vector-ref spec 2))
             (previous (vector-ref spec 3))
             (heap (context-datum-heap (native-bridge-context bridge)))
             (owned (vector-ref entry 0))
             (snapshot (vector-ref entry 3)))
        (if (not (native-slot-value-same? current previous))
            (case (vector-ref entry 2)
              ((pair)
               (if (= slot 0)
                   (consent-datum-set-car! heap owned value)
                   (consent-datum-set-cdr! heap owned value)))
              ((vector)
               (consent-datum-vector-set! heap owned slot value))))
        (vector-set! snapshot slot current)))

    (define (native-bridge-reconcile-values bridge values)
      "Own native VALUES and synchronize mapped compound mutations."
      (let* ((entries (native-bridge-entries bridge))
             (specs (native-bridge-slot-specs entries))
             (fresh-node-count 0)
             (all-values
              (append values
                      (map (lambda (spec) (vector-ref spec 2)) specs)))
             (converted
              (if (null? all-values)
                  '()
                  (let* ((length (length all-values))
                         (root (list->vector all-values))
                         (owned-root
                          (consent-datum-import
                           (context-datum-heap
                            (native-bridge-context bridge))
                           root
                           (lambda (value)
                             (native-result-leaf
                              value (native-bridge-context bridge)))
                           (lambda (target source)
                             ;; ROOT is an importer-only result carrier. Every
                             ;; other callback denotes one genuinely fresh
                             ;; owned compound; reused borrowed mirrors bypass
                             ;; allocation and this callback entirely.
                             (set! fresh-node-count
                                   (+ fresh-node-count
                                      (native-bridge-register-imported!
                                       bridge target source root))))
                           (lambda (source absent)
                             (native-bridge-import-reuse
                              bridge source absent)))))
                    (let extract ((index 0) (result '()))
                      (if (= index length)
                          (reverse result)
                          (extract
                           (+ index 1)
                           (cons
                            (consent-datum-vector-ref owned-root index)
                            result)))))))
             (result-count (length values)))
        (let apply-slots ((rest specs)
                          (owned-values
                           (let drop ((count result-count)
                                      (rest converted))
                             (if (= count 0)
                                 rest
                                 (drop (- count 1) (cdr rest))))))
          (if (pair? rest)
              (begin
                (native-bridge-apply-slot!
                 bridge (car rest) (car owned-values))
                (apply-slots (cdr rest) (cdr owned-values)))))
        (let sync-atomic ((rest entries))
          (if (pair? rest)
              (begin
                (native-bridge-sync-atomic-entry! bridge (car rest))
                (sync-atomic (cdr rest)))))
        ;; Reconciliation first publishes all host-side mutations. The charge
        ;; then covers exactly the fresh result/writeback graph that became
        ;; owned, without walking or charging any reused argument subgraph.
        (if (> fresh-node-count 0)
            (note-value-allocation!
             (native-bridge-context bridge) fresh-node-count))
        (let take ((count result-count) (rest converted) (result '()))
          (if (= count 0)
              (reverse result)
              (take (- count 1) (cdr rest) (cons (car rest) result))))))

    (define (native-scalar-result-values? values)
      "Report whether VALUES contain no compound datum requiring import."
      (let loop ((rest values))
        (or
         (null? rest)
         (and
          (not
           (or (consent-datum-object? (car rest))
               (pair? (car rest))
               (string? (car rest))
               (vector? (car rest))
               (bytevector? (car rest))))
          (loop (cdr rest))))))

    (define (native-bridge-native-values->owned bridge values)
      "Convert native VALUES and synchronize any mapped mutations."
      (if (and (native-bridge-compound-prohibition bridge)
               (not (native-scalar-result-values? values)))
          (native-bridge-reject-compound!
           (native-bridge-compound-prohibition bridge)))
      ;; A scalar-only call has neither borrowed entries nor result topology to
      ;; preserve. Convert leaves directly, avoiding substitution maps, the
      ;; temporary root vector, and a datum-import traversal.
      (if (and (null? (native-bridge-entries bridge))
               (native-scalar-result-values? values))
          (map
           (lambda (value)
             (native-result-leaf value (native-bridge-context bridge)))
           values)
          (native-bridge-reconcile-values bridge values)))

    ;; Owner libraries expose representation records whose exact identity must
    ;; survive native compilation in both directions. Their procedures perform
    ;; any explicit host projection themselves.
    (define native-preserved-owner-libraries
      '((consent datum)))

    ;; Some internal-library exports operate on reader-owned Consent datums
    ;; whose
    ;; identity must survive the native call boundary intact: source-metadata
    ;; accessors key off the original pair/vector/string object, character
    ;; accessors inspect owned records, and numeric predicates inspect
    ;; canonical
    ;; number records instead of host-unwrapped payloads. Most other portable
    ;; libraries still want ordinary host-facing scalar conversion.
    (define native-preserved-argument-bindings
      '((((consent character)
          consent-character?
          consent-character-code
          consent-character-equivalent?
          consent-character->host-character))
        (((consent symbol)
          consent-symbol?
          consent-symbol-name
          consent-symbol-equivalent?
          consent-symbol=?
          consent-symbol-table?
          consent-symbol-table-from-root
          consent-symbol-table-root
          consent-symbol-table-root-set!))
        (((consent symbol-boundary)
          consent-host-symbol?
          consent-host-symbol-name
          consent-host-symbol-eq?
          consent-host-symbol-eqv?
          consent-host-symbol-equal?
          consent-host-symbol-memq
          consent-host-symbol-assq
          consent-host-symbol-member
          consent-host-symbol-assoc))
        (((consent library)
          consent-native-argument-value
          consent-runtime-datum->native-datum
          consent-call-native-library
          consent-apply-callable))
        (((consent runtime)
          primitive-procedure-documentation
          set-primitive-procedure-documentation!))
        (((consent macro) consent-syntax-source))
        (((consent eval)
          consent-result->external
          consent-value->external))
        (((consent interpreter)
          consent-result->external
          consent-value->external))
        (((consent result)
          consent-result->external
          consent-value->external))
        (((consent reader)
          consent-datum-source-metadata
          consent-source-metadata->record
          consent-datum-source
          consent-datum-source-set!
          consent-copy-datum-source!
          consent-datum->external
          consent-number?
          consent-number-lexeme
          consent-number-exactness
          consent-number-radix
          consent-number-kind
          consent-number-value
          consent-number-zero?
          consent-number-negative?
          consent-number-abs
          consent-number->external
          consent-character?
          consent-character-code))))

    ;; Representation APIs return identity-bearing values whose exact symbol
    ;; table or container provenance is part of their contract. The general
    ;; result bridge must neither collapse those identities nor undo explicit
    ;; conversion to native data.
    (define native-preserved-result-bindings
      '((((consent symbol)
          consent-symbol?
          consent-symbol-name
          consent-symbol-equivalent?
          consent-symbol=?
          consent-symbol-table?
          consent-make-symbol-table
          consent-symbol-table-from-root
          consent-symbol-table-root
          consent-symbol-table-root-set!
          consent-intern-symbol
          consent-default-symbol-table))
        (((consent symbol-boundary)
          consent-host-symbol?
          consent-host-symbol-name
          consent-host-symbol-eq?
          consent-host-symbol-eqv?
          consent-host-symbol-equal?
          consent-host-symbol-memq
          consent-host-symbol-assq
          consent-host-symbol-member
          consent-host-symbol-assoc))
        (((consent reader)
          consent-datum-source-metadata))))

    ;; Accessors that intentionally publish a host scalar payload should keep
    ;; that surface instead of rewrapping the result back into a Consent
    ;; number.
    (define native-host-result-bindings
      '((((consent reader) consent-number-value))))

    ;; Compiled higher-order libraries need interpreted callable arguments
    ;; adapted to host procedures. The library implementation remains the same
    ;; portable Scheme source; only the borrowed-host call ABI needs this shim.
    (define native-callback-argument-libraries
      '((data avl-tree)
        (agent generated-source)))

    ;; Only these compiled bindings may borrow owned compounds through the
    ;; call-scoped graph adapter. Higher-order or retaining libraries stay on
    ;; their source realization instead of widening this private ABI.
    (define native-compound-borrow-bindings
      '((((agent memory-query)
          memory-query-find
          memory-query-by-tag
          memory-query-recent
          memory-query-select))
        (((agent models openai-codec)
          model-openai-codec-request-json-projected
          model-openai-codec-parse-response
          model-openai-codec-provider-error-projected))
        (((agent redaction-kernel)
          redaction-kernel-secret-string?))
        (((agent task)
          task-state?
          task-transition-allowed?
          validate-task-transition
          make-task-condition
          task-field-value
          task-record?
          agent-task?
          agent-step?
          agent-action?
          agent-observation?
          agent-decision?
          task-pause?
          task-stop?
          task-wait?
          task-failure?
          agent-completion?
          task-record-valid?
          validate-task-record
          make-agent-task
          make-agent-step
          make-agent-action
          make-agent-observation
          make-agent-decision
          make-task-pause
          make-task-stop
          make-task-wait
          make-task-failure
          make-agent-completion))
        (((agent transcript)
          make-transcript-event
          transcript-event?
          transcript-field-value
          transcript-event-replay-mode
          transcript-replayable?
          transcript-recorded-observation?
          transcript-event->fixture-case
          transcript-event-summary
          transcript-raw-view
          transcript-summary-view
          transcript-rotate
          transcript-export))
        (((agent context)
          context-field
          context-present?
          make-request-context
          make-conversation-summary
          make-focus-context
          make-context-bundle))))

    ;; Immutable data bindings that native code may borrow directly. Empty
    ;; entries make a procedure-only inventory's zero-data contract explicit.
    (define native-compound-borrow-data-bindings
      '((((agent memory-query)))
        (((agent models openai-codec)))
        (((agent redaction-kernel)))
        (((agent task)
          task-states
          task-pause-states
          task-terminal-states
          task-allowed-transitions
          task-pause-reasons
          task-stop-reasons))
        (((agent transcript)
          transcript-event-kinds
          transcript-replay-modes
          transcript-export-formats
          transcript-retention-default))
        (((agent context)))))

    ;; A small number of directly linked core bindings safely copy a compound
    ;; argument during the call without retaining its borrowed mirror. Keep
    ;; these exceptions separate from the six complete agent inventories:
    ;; adding one core binding must not make every export in that owner part of
    ;; the call-scoped borrow ABI.
    (define native-core-compound-borrow-bindings
      '((((consent symbol) consent-intern-symbol))))

    (define (native-binding-policy-member? table library-key name)
      "Report whether TABLE marks NAME in LIBRARY-KEY for special handling."
      (let loop ((rest table))
        (if (null? rest)
            #f
            (let ((entry (car rest)))
              (if (library-datum-equal? (caar entry) library-key)
                  (library-memq name (cdar entry))
                  (loop (cdr rest)))))))

    (define (native-binding-policy-names table library-key)
      "Return TABLE's names for LIBRARY-KEY, or #f when it is absent."
      (let loop ((rest table))
        (if (null? rest)
            #f
            (let ((entry (car rest)))
              (if (library-datum-equal? (caar entry) library-key)
                  (cdar entry)
                  (loop (cdr rest)))))))

    (define (native-interpreted-callable? value)
      "Report whether VALUE is a callable owned by the interpreter."
      (or (consent-procedure? value)
          (consent-primitive-procedure? value)
          (continuation? value)
          (consent-parameter? value)))

    (define (native-binding-table-ref bindings name)
      "Return NAME's native binding pair from BINDINGS, or #f."
      (let loop ((rest bindings))
        (cond
         ((null? rest) #f)
         ((library-symbol-eq? name (car (car rest))) (car rest))
         (else (loop (cdr rest))))))

    (define (validate-native-borrow-binding-inventory! key bindings)
      "Validate the complete typed compound-borrow inventory for KEY."
      (let ((procedure-names
             (native-binding-policy-names
              native-compound-borrow-bindings key)))
        (if procedure-names
            (let ((data-names
                   (native-binding-policy-names
                    native-compound-borrow-data-bindings key)))
              (let actual-loop ((rest bindings) (seen '()))
                (if (pair? rest)
                    (let* ((binding (car rest))
                           (name (car binding))
                           (allowed?
                            (if (procedure? (cdr binding))
                                (library-memq name procedure-names)
                                (and data-names
                                     (library-memq name data-names)))))
                      (if (or (library-memq name seen) (not allowed?))
                          (error
                           (string-append
                            "native-binding-inventory-mismatch: "
                            "unexpected binding")))
                      (actual-loop (cdr rest) (cons name seen)))))
              (let procedure-loop ((rest procedure-names))
                (if (pair? rest)
                    (let ((binding
                           (native-binding-table-ref bindings (car rest))))
                      (if (not (and binding (procedure? (cdr binding))))
                          (error
                           (string-append
                            "native-binding-inventory-mismatch: "
                            "missing procedure")))
                      (procedure-loop (cdr rest)))))
              (let data-loop ((rest data-names))
                (if (pair? rest)
                    (let ((binding
                           (native-binding-table-ref bindings (car rest))))
                      (if (not (and binding
                                    (not (procedure? (cdr binding)))))
                          (error
                           "native-binding-inventory-mismatch: missing data"))
                      (data-loop (cdr rest)))))))))

    (define (native-binding-name-count bindings name)
      "Return how many BINDINGS entries are named NAME."
      (let loop ((rest bindings) (count 0))
        (if (null? rest)
            count
            (loop
             (cdr rest)
             (if (library-symbol-eq? name (car (car rest)))
                 (+ count 1)
                 count)))))

    (define (validate-native-core-borrow-bindings! key bindings)
      "Validate every sparse core borrow exception for native library KEY."
      (let ((names
             (native-binding-policy-names
              native-core-compound-borrow-bindings key)))
        (if names
            (let loop ((rest names) (seen '()))
              (if (pair? rest)
                  (let* ((name (car rest))
                         (binding (native-binding-table-ref bindings name)))
                    (if (or (library-memq name seen)
                            (not (= (native-binding-name-count bindings name)
                                    1))
                            (not (and binding (procedure? (cdr binding)))))
                        (error
                         (string-append
                          "native-binding-inventory-mismatch: "
                          "invalid core borrow binding")))
                    (loop (cdr rest) (cons name seen))))))))

    (define (native-binding-argument-policy library-key name)
      "Return how NAME in LIBRARY-KEY should receive its arguments."
      (cond
       ((or (library-member library-key native-preserved-owner-libraries)
            (native-binding-policy-member?
             native-preserved-argument-bindings
             library-key
             name))
        'preserve)
       ((library-member library-key native-callback-argument-libraries)
        'callback)
       (else 'convert)))

    (define (native-binding-result-policy library-key name)
      "Return how NAME in LIBRARY-KEY should publish its result."
      (cond
       ((or (library-member library-key native-preserved-owner-libraries)
            (native-binding-policy-member?
             native-preserved-result-bindings
             library-key
             name))
        'preserve)
       ((native-binding-policy-member?
         native-host-result-bindings
         library-key
         name)
        'host)
       (else 'consent)))

    (define (native-binding-argument library-key name argument context)
      "Bridge one ARGUMENT for NAME in LIBRARY-KEY into native code."
      (let ((policy (native-binding-argument-policy library-key name)))
        (cond
         ((library-symbol-eq? policy 'preserve) argument)
         ((and (library-symbol-eq? policy 'callback)
               (native-interpreted-callable? argument))
          (native-callback-shim argument context #t))
         (else
          (native-argument-value-with-policy
           argument
           context
           (or
            (not (library-symbol-eq? policy 'convert))
            (native-binding-policy-member?
             native-compound-borrow-bindings library-key name)
            (native-binding-policy-member?
             native-core-compound-borrow-bindings library-key name)))))))

    (define (native-binding-result library-key name value)
      "Bridge native VALUE back for NAME in LIBRARY-KEY."
      (let ((policy (native-binding-result-policy library-key name)))
        (cond
         ((library-symbol-eq? policy 'preserve) value)
         ((library-symbol-eq? policy 'host)
          (native-callback-result value #t))
         (else (native-result-value value)))))

    (define (native-binding-results
             library-key name bridge results)
      "Bridge one native binding's RESULTS through its per-call BRIDGE."
      (let ((policy (native-binding-result-policy library-key name)))
        (cond
         ((library-symbol-eq? policy 'consent)
          (native-converted-results-value
           (native-bridge-native-values->owned bridge results)))
         (else
          ;; Preserved and explicitly host-facing results do not enter the
          ;; owned heap, but mutations to converted arguments still do.
          (native-bridge-native-values->owned bridge '())
          (native-converted-results-value
           (map
            (lambda (value)
              (if (library-symbol-eq? policy 'preserve)
                  value
                  (native-callback-result value #t)))
            results))))))

    (define (consent-apply-callable value arguments)
      "Apply callable VALUE to ARGUMENTS across the native import boundary."
      "Host procedures apply directly. An interpreted callable -- a closure"
      "a self-hosted program passes as a bare argument into a natively bound"
      "higher-order procedure such as the REPL engine's input driver -- runs"
      "through the native callback shim in the calling program's context,"
      "with the shim's argument and result conversions."
      #((parameters
         (value (type procedure)
          (description "Host procedure or interpreted callable to apply."))
         (arguments (type list)
          (description "List of arguments to pass to the callable.")))
        (returns . "The value produced by applying VALUE to ARGUMENTS.")
        (effects host-eval))
      (if (procedure? value)
          (apply value arguments)
          (apply (native-callback-shim value native-call-context #f)
                 arguments)))

    (define (native-nested-argument
             value context . maybe-allow-borrow?)
      "Convert one value nested inside a container crossing into native code."
      "Callables nested in data follow the callback convention -- a custom"
      "reader resync strategy or a policy-confirmation-function inside an"
      "options alist -- so they become host callbacks native higher-order"
      "code can apply directly. Ordinary `(scheme base)' scalar data keep"
      "their language-level surface here too: owned symbols and characters,"
      "canonical number records, and the interpreter's eof record become host"
      "Scheme values"
      "instead of leaking reader/runtime representation details into native"
      "consumers. One worklist crosses host and owned nodes without recursion."
      (let ((bridge (current-native-graph-bridge context))
            (allow-borrow?
             (or (null? maybe-allow-borrow?)
                 (car maybe-allow-borrow?))))
        (if bridge
            (native-bridge-owned->native
             bridge value #t allow-borrow?)
            (call-with-fresh-native-egress-state
             (lambda (state)
               (native-egress-graph
                value
                state
                (lambda (leaf)
                  (cond
                   ((consent-symbol? leaf)
                    (host-string->symbol (consent-symbol-name leaf)))
                   ((consent-character? leaf)
                    (consent-character->host-character leaf))
                   ((consent-number? leaf)
                    (native-number-or-owned leaf))
                   ((consent-eof-object? leaf) (eof-object))
                   ((or (consent-procedure? leaf)
                        (consent-primitive-procedure? leaf)
                        (continuation? leaf)
                        (consent-parameter? leaf))
                    (native-callback-shim leaf context #t))
                   (else leaf)))
                native-copy-source-noop!
                native-owned-reuse-none
                native-owned-allocation-noop!
                native-copy-source-noop!
                (if allow-borrow?
                    native-egress-authorize-any!
                    native-egress-reject-borrow!)))))))

    (define (native-argument-value-with-policy
             value context allow-borrow?)
      "Convert VALUE for CONTEXT under explicit ALLOW-BORROW?."
      (if (and (not allow-borrow?)
               (native-interpreted-callable? value))
          (native-egress-reject-borrow! value))
      (if (or (pair? value)
              (vector? value)
              (consent-datum-object? value)
              (consent-symbol? value)
              (consent-character? value)
              (consent-number? value)
              (consent-eof-object? value))
          (let ((bridge (current-native-graph-bridge context)))
            (if bridge
                (native-bridge-owned->native
                 bridge value #t allow-borrow?)
                (native-nested-argument
                 value context allow-borrow?)))
          value))

    (define (consent-native-argument-value value context)
      "Convert one argument crossing into native code."
      "A bare callable argument crosses unchanged: it is the runtime's own"
      "procedure record, which native predicates, accessors, and the shared"
      "apply machinery already handle (consent-procedure? on a"
      "consent-eval-source result must see the record, not a wrapper)."
      "Symbols, characters, bounded numbers, and eof objects cross as plain"
      "host Scheme values; larger numbers retain owned storage. Containers are\
"
      "walked so"
      "nested scalars and the options-alist callback convention both preserve"
      "the portable library surface."
      #((parameters
         (value (type object)
          (description
           ("Portable argument value about to cross into a native binding.")))
         (context (type eval-context)
          (description
           ("Evaluation context that nested callable shims should re-enter"
            "when native higher-order code applies them."))))
        (returns (type object)
         (description
          ("VALUE converted to the host-facing argument form: host symbols,"
           "characters, numbers, or eof objects for scalar runtime records;"
           "host callbacks for nested callables; and topology-preserving host"
           "containers for owned graph arguments.")))
        (effects pure allocation))
      (native-argument-value-with-policy value context #t))

    (define (native-result-procedure procedure context)
      "Return the runtime wrapper for native PROCEDURE in CONTEXT."
      (or (native-callback-origin procedure)
          ;; R7RS does not require repeated procedure results to be `eqv?'.
          ;; A fresh wrapper avoids retaining every transient host closure in
          ;; a long-lived evaluation context's static binding-cell cache.
          (native-binding-value
           '(native result) 'result procedure #f)))

    (define (native-result-leaf value context)
      "Convert native scalar VALUE for runtime CONTEXT."
      (cond
       ((and context (consent-symbol? value))
        (consent-intern-symbol
         (context-symbol-table context)
         (consent-symbol-name value)))
       ((and context (host-symbol? value))
        (consent-intern-symbol
         (context-symbol-table context)
         (host-symbol->string value)))
       (else
        (consent-host-datum->consent-datum
         value
         (lambda (procedure)
           (native-result-procedure procedure context))))))

    (define (native-result-owned-by-context? datum context)
      "Report whether DATUM is already owned by CONTEXT's compound heap."
      (and
       (consent-datum-object? datum)
       (= (consent-datum-object-heap-id datum)
          (consent-datum-heap-id (context-datum-heap context)))))

    (define (require-native-result-fast-identity-maps!)
      "Reject general native result imports without identity hashing."
      (if (not (consent-identity-map-fast-backend?))
          (error
           "native-result-import-unavailable: fast identity maps are \
required")))

    (define (native-own-result-datum datum context)
      "Import native DATUM into CONTEXT's owned compound heap."
      "The shared datum importer memoizes source objects before descending,"
      "so aliases and cycles cross the private host adapter exactly once."
      "Scalars and same-heap owned objects need no identity map. Every fresh"
      "host or cross-heap compound requires a hash-backed map: even flat host"
      "values can carry provenance in an unbounded identity side table."
      (cond
       ((native-result-owned-by-context? datum context) datum)
       ((not
         (or (consent-datum-object? datum)
             (pair? datum)
             (string? datum)
             (vector? datum)
             (bytevector? datum)))
        (native-result-leaf datum context))
       (else
        (require-native-result-fast-identity-maps!)
        (let ((fresh-node-count 0))
          (let ((owned
                 (consent-datum-import
                  (context-datum-heap context)
                  datum
                  (lambda (value) (native-result-leaf value context))
                  (lambda (target source)
                    (set! fresh-node-count
                          (+ fresh-node-count
                             (native-imported-node-cost target)))
                    (context-copy-datum-source!
                     context target source #t)))))
            (if (> fresh-node-count 0)
                (note-value-allocation! context fresh-node-count))
            owned)))))

    (define (native-result-value value . maybe-context)
      "Convert one native RESULT for interpreted use."
      "Native unwrap accessors return raw host numbers (consent-number-value,"
      "read positions); interpreted callers expect canonical records,"
      "mirroring how char->integer wraps at the primitive boundary. A raw"
      "host procedure result (a REPL chrome lookup, for example) wraps as a"
      "native primitive through the shared binding cells so repeated lookups"
      "stay eqv? and the interpreted world can both recognize and apply it."
      "Every host compound result is imported through the active context's"
      "memoized datum heap conversion, which preserves aliases, cycles, and"
      "source provenance while canonicalizing scalar leaves."
      (let ((context
             (if (null? maybe-context)
                 native-call-context
                 (car maybe-context))))
        (if context
            (let ((bridge (current-native-graph-bridge context)))
              (if bridge
                  (car
                   (native-bridge-native-values->owned
                    bridge (list value)))
                  (native-own-result-datum value context)))
            (native-result-leaf value #f))))

    (define (native-results-value results converter)
      "Convert host RESULTS with CONVERTER and preserve multiple values."
      (let ((converted (map converter results)))
        (if (and (pair? converted) (null? (cdr converted)))
            (car converted)
            (make-multiple-values converted))))

    (define (native-converted-results-value results)
      "Return converted RESULTS as one value or a multiple-values wrapper."
      (if (and (pair? results) (null? (cdr results)))
          (car results)
          (make-multiple-values results)))

    (define (invoke-with-native-condition-bridge
             bridge invoke . maybe-reconciliation-state)
      "Invoke through BRIDGE and own any arbitrary raised native datum."
      ;; Return a tagged outcome from `guard' and raise only after its handler
      ;; has exited. Gauche bypasses an enclosing exception handler when a
      ;; `guard' clause itself raises, which would let native failures escape
      ;; top-level evaluation-result capture.
      (let ((start-reconciliation!
             (if (pair? maybe-reconciliation-state)
                 (car maybe-reconciliation-state)
                 (lambda () #f)))
            (complete-reconciliation!
             (if (and (pair? maybe-reconciliation-state)
                      (pair? (cdr maybe-reconciliation-state)))
                 (cadr maybe-reconciliation-state)
                 (lambda () #f)))
            (outcome
             (guard
              (condition (else (cons #f condition)))
              (call-with-values
               (lambda () (invoke bridge))
               (lambda results (cons #t results))))))
        (if (car outcome)
            (apply values (cdr outcome))
            (let ((condition (cdr outcome)))
              ;; Conversion still occurs while the bridge is active, so
              ;; raising a current argument or subobject preserves its owned
              ;; identity. Native error objects become the runtime's portable
              ;; error record before a borrowed host can render an owned
              ;; irritant as opaque host data.
              (start-reconciliation!)
              (let ((owned-condition
                     (if (error-object? condition)
                         (let ((irritants
                                (error-object-irritants condition)))
                           ;; Guile's R7RS adapter returns #f, rather than the
                           ;; required empty list, for an error with no
                           ;; irritants. Normalize that host representation at
                           ;; the boundary before graph reconciliation.
                           (make-consent-error-object
                            (error-object-message condition)
                            (native-bridge-native-values->owned
                             bridge
                             (if (list? irritants) irritants '()))))
                         (car
                          (native-bridge-native-values->owned
                           bridge (list condition))))))
                (complete-reconciliation!)
                (raise owned-condition))))))

    (define (call-with-native-graph-bridge context invoke receive)
      "Invoke one native call through CONTEXT's outer-call graph bridge."
      (let ((active (current-native-graph-bridge context)))
        (if active
            ;; Re-entrant calls share the outer transaction only for scalars.
            ;; Compound state would require repeated scans for uninstrumented
            ;; host mutations, so reject it instead of hiding quadratic work.
            (call-with-native-scalar-only-bridge
             active
             'reentrant
             (lambda ()
               (let ((previous-context native-call-context)
                     (previous-bridge-context
                      (native-bridge-context active)))
                 (dynamic-wind
                  (lambda ()
                    (set! native-call-context context)
                    (set-native-bridge-context! active context))
                  (lambda ()
                    (call-with-values
                     (lambda ()
                       (invoke-with-native-condition-bridge active invoke))
                     (lambda results (receive active results))))
                  (lambda ()
                    (set! native-call-context previous-context)
                    (set-native-bridge-context!
                     active previous-bridge-context))))))
            (let ((previous-context native-call-context)
                  (previous-bridge native-call-graph-bridge)
                  (bridge (make-native-graph-bridge context))
                  (reconciliation-state 'pending))
              (dynamic-wind
               (lambda ()
                 (set! native-call-context context)
                 (set! native-call-graph-bridge bridge))
               (lambda ()
                 (call-with-values
                  (lambda ()
                    (invoke-with-native-condition-bridge
                     bridge
                     invoke
                     (lambda ()
                       (set! reconciliation-state 'started))
                     (lambda ()
                       (set! reconciliation-state 'completed))))
                  (lambda results
                    (set! reconciliation-state 'started)
                    (let ((value (receive bridge results)))
                      (set! reconciliation-state 'completed)
                      value))))
               (lambda ()
                 ;; Restore dynamic state before a writeback error can escape.
                 (set! native-call-context previous-context)
                 (set! native-call-graph-bridge previous-bridge)
                 ;; Mutations performed before a native exception remain
                 ;; observable. Release the intrusive header map even when
                 ;; reconciliation itself raises.
                 (dynamic-wind
                  (lambda () #t)
                  (lambda ()
                    (if (library-symbol-eq?
                         reconciliation-state 'pending)
                        (begin
                          (set! reconciliation-state 'started)
                          (native-bridge-native-values->owned bridge '())
                          (set! reconciliation-state 'completed))))
                  (lambda ()
                    (native-owned-state-release!
                     (native-bridge-owned-index bridge))))))))))

    (define (consent-call-native-library procedure context . arguments)
      "Call native PROCEDURE through the runtime representation boundary."
      "CONTEXT is installed for the complete call so nested callbacks and"
      "re-entrant native calls use the innermost evaluator's symbol table."
      #((parameters
         (procedure (type procedure)
          (description "Compiled portable-library procedure to call."))
         (context (type eval-context)
          (description "Evaluation context owning the call."))
         (arguments (type list)
          (description "Runtime arguments supplied to PROCEDURE.")))
        (returns (type object)
         (description "PROCEDURE's result converted back into CONTEXT."))
        (effects procedure-call allocation))
      (call-with-native-graph-bridge
       context
       (lambda (bridge)
         (apply procedure
                (map (lambda (argument)
                       (consent-native-argument-value argument context))
                     arguments)))
       (lambda (bridge results)
         (native-converted-results-value
          (native-bridge-native-values->owned bridge results)))))

    (define (native-binding-value
             library-key
             name
             value
             .
             maybe-documentation)
      "Wrap native VALUE for interpreted use."
      "Host procedures become primitives whose arguments are converted under"
      "the two boundary conventions (bare callables cross as the runtime's"
      "own records, callables nested in data cross as host callbacks) and"
      "whose results are converted so raw host numbers come back canonical;"
      "every other value binds directly, because the compiled internal"
      "libraries share the runtime's value representations. The primitive"
      "name is prefixed so it can never collide with the interpreter's"
      "continuation-passing primitive dispatch names."
      (if (procedure? value)
          (make-primitive-procedure
           (host-string->symbol
            (string-append "native:" (library-symbol-name name)))
           (lambda (arguments context)
             (call-with-native-graph-bridge
              context
              (lambda (bridge)
                (apply value
                       (map (lambda (argument)
                              (native-binding-argument
                               library-key
                               name
                               argument
                               context))
                            arguments)))
              (lambda (bridge results)
                (native-binding-results
                 library-key name bridge results))))
           0
           #f
           (if (null? maybe-documentation)
               #f
               (car maybe-documentation)))
          ;; Exported data values (for example consent-version-datum) may carry
          ;; raw host numbers a native reader would consume directly; convert
          ;; them once at registration so interpreted callers see canonical
          ;; numbers.
          (native-binding-result library-key name value)))

    (define (ensure-context-native-binding-cache! context)
      "Return CONTEXT's native binding cache, allocating it when absent."
      "Native registration and result wrapping require the hash-backed"
      "identity-map adapter before populating this ultra-critical cache."
      (or (context-native-binding-cache context)
          (begin
            (require-native-fast-identity-maps!)
            (let ((cache (consent-make-identity-map)))
              (set-context-native-binding-cache! context cache)
              cache))))

    (define (native-binding-cache-level! cache key)
      "Return CACHE's identity-keyed child map for KEY, creating it once."
      (or (consent-identity-map-ref cache key #f)
          (let ((created (consent-make-identity-map)))
            (consent-identity-map-set! cache key created)
            created)))

    (define (native-binding-cell library-key name value context)
      "Return CONTEXT's shared binding cell for native VALUE."
      "The context-local nested identity maps key VALUE, argument policy,"
      "then result policy. This preserves binding-location identity across"
      "same-context re-exports without scanning or retaining process history."
      (let* ((argument-policy
              (native-binding-argument-policy library-key name))
             (result-policy
              (native-binding-result-policy library-key name))
             (documentation
              (consent-native-library-documentation-ref
               library-key
               name))
             (value-cache
              (native-binding-cache-level!
               (ensure-context-native-binding-cache! context)
               value))
             (argument-cache
              (native-binding-cache-level!
               value-cache argument-policy))
             (existing
              (consent-identity-map-ref
               argument-cache result-policy #f))
             (cell
              (or existing
                  (let ((created
                         (make-cell
                          (if (procedure? value)
                              (native-binding-value
                               library-key
                               name
                               value
                               documentation)
                              (let ((previous native-call-context))
                                (dynamic-wind
                                 (lambda ()
                                   (set! native-call-context context))
                                 (lambda ()
                                   (native-binding-value
                                    library-key
                                    name
                                    value
                                    documentation))
                                 (lambda ()
                                   (set! native-call-context previous))))))))
                    (consent-identity-map-set!
                     argument-cache result-policy created)
                    created))))
        (if documentation
            (set-primitive-procedure-documentation!
             (cell-value cell) documentation))
        cell))

    (define (register-native-library! key bindings context)
      "Register internal library KEY from its compiled-in native BINDINGS tabl\
e."
      (validate-native-borrow-binding-inventory! key bindings)
      (validate-native-core-borrow-bindings! key bindings)
      ;; The binding-cell cache itself is an ultra-critical identity lookup,
      ;; independent of whether this particular library exports compound data.
      (require-native-fast-identity-maps!)
      (ensure-context-native-binding-cache! context)
      (let ((value-environment (consent-make-empty-environment))
            (syntax-environment (library-make-empty-syntax-environment #f)))
        (for-each
         (lambda (binding)
           (set-environment-frame!
            value-environment
            (cons (cons (car binding)
                        (native-binding-cell key
                                             (car binding)
                                             (cdr binding)
                                             context))
                  (environment-frame value-environment))))
         bindings)
        (library-registry-set!
         context
         key
         (make-library
          key
          key
          (snapshot-library-bindings
           value-environment
           syntax-environment
           key)
          value-environment
          syntax-environment))))

    (define (find-library-export name exports)
      "Return NAME's binding from EXPORTS, or #f when absent."
      (cond
       ((null? exports) #f)
       ((library-symbol-eq? name (library-binding-name (car exports))) (car
         exports))
       (else (find-library-export name (cdr exports)))))

    (define (register-subset-library! key export-names context environment)
      "Register KEY as a subset of `(scheme base)' exports."
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (exports
                  (map
                   (lambda (name)
                     (or (find-library-export name base-exports)
                         (eval-error
                          "standard library binding is not available"
                          name)))
                   export-names)))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              exports
              (library-value-environment base-library)
              (library-syntax-environment base-library))))))

    (define (filter-library-exports exports export-names key)
      "Return EXPORTS narrowed to EXPORT-NAMES for alias library KEY."
      (for-each
       (lambda (name)
         (if (not (find-library-export name exports))
             (eval-error "alias export is not available" key name)))
       export-names)
      (let loop ((rest exports) (result '()))
        (cond
         ((null? rest) (reverse result))
         ((library-memq (library-binding-name (car rest)) export-names)
          (loop (cdr rest) (cons (car rest) result)))
         (else (loop (cdr rest) result)))))

    (define (register-library-alias! spec context environment)
      "Register alias SPEC using its target library and optional exports."
      (let ((key (library-alias-field spec 'alias))
            (target-key (library-alias-field spec 'target))
            (export-names-entry (library-assq 'exports spec)))
        (if (not key)
            (eval-error "library alias has no alias name" spec))
        (if (not target-key)
            (eval-error "library alias has no target" key))
        (if (not (library-registry-ref context key))
            (let* ((target-library
                    (resolve-library target-key context environment))
                   (target-exports (library-exports target-library)))
              (library-registry-set!
               context
               key
               (make-library
                key
                key
                (if export-names-entry
                    (filter-library-exports
                     target-exports
                     (cdr export-names-entry)
                     key)
                    target-exports)
                (library-value-environment target-library)
                (library-syntax-environment target-library)))))))

    (define (manifest-entry-exports-declared? entry)
      "Report whether manifest ENTRY explicitly declares exports."
      (or (collection-entry-field entry 'exports-declared? #f)
          (and (not (library-assq 'exports-declared? entry))
               (library-assq 'exports entry)
               #t)))

    (define (manifest-library-alias-spec entry)
      "Return alias registration metadata for manifest ENTRY."
      (let ((key (collection-entry-field entry 'name #f))
            (target (collection-entry-field entry 'target #f))
            (exports-declared? (manifest-entry-exports-declared? entry))
            (exports (collection-entry-field entry 'exports '())))
        (if (not target)
            (eval-error "manifest alias has no target" key))
        (append
         (list (cons 'alias key)
               (cons 'target target))
         (if (not exports-declared?)
             '()
             (list (cons 'exports exports))))))

    (define (library-alias-spec key aliases)
      "Return KEY's alias spec from ALIASES, or #f when KEY is not an alias."
      (cond
       ((null? aliases) #f)
       ((library-datum-equal? key (library-alias-field (car aliases) 'alias))
        (car aliases))
       (else (library-alias-spec key (cdr aliases)))))

    (define (register-primitive-library! key primitive-specs context)
      "Register KEY as a library populated from primitive specs."
      (if (not (library-registry-ref context key))
          (let ((value-environment (consent-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment
                  #f)))
            (for-each
             (lambda (spec)
               (define-primitive!
                value-environment
                (car spec)
                (second spec)
                (third spec)
                (fourth spec)))
             primitive-specs)
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              (snapshot-library-bindings
               value-environment
               syntax-environment
               key)
              value-environment
              syntax-environment)))))

    (define (library-exports-with-binding exports binding)
      "Return EXPORTS with BINDING replacing the same-named export."
      (let ((name (library-binding-name binding)))
        (let loop ((rest exports) (replaced? #f) (result '()))
          (cond
           ((null? rest)
            (reverse (if replaced? result (cons binding result))))
           ((library-symbol-eq? (library-binding-name (car rest)) name)
            (loop (cdr rest) #t (cons binding result)))
           (else
            (loop (cdr rest) replaced? (cons (car rest) result)))))))

    (define (register-library-primitive-bindings! key primitive-specs context)
      "Overlay PRIMITIVE-SPECS onto the already registered source library KEY.\
"
      (let ((library (library-registry-ref context key)))
        (if (not library)
            (eval-error "source library is not registered" key))
        (let ((value-environment (library-value-environment library))
              (exports (library-exports library)))
          (for-each
           (lambda (spec)
             (let ((name (car spec)))
               (define-primitive!
                value-environment
                name
                (second spec)
                (third spec)
                (fourth spec))
               (set! exports
                     (library-exports-with-binding
                      exports
                      (make-library-binding
                       name
                       'value
                       (environment-cell value-environment name)
                       key)))))
           primitive-specs)
          (library-registry-set!
           context
           key
           (make-library
            (library-name library)
            (library-key library)
            exports
            value-environment
            (library-syntax-environment library))))))

    (define (primitive-library-required-field entry field description)
      "Return FIELD from ENTRY or raise DESCRIPTION."
      (let ((cell (library-assq field entry)))
        (if cell
            (cadr cell)
            (eval-error
             (string-append description " missing field")
             field))))

    (define (validate-primitive-library-export export declaration)
      "Validate primitive EXPORT metadata for DECLARATION."
      (let ((name
             (primitive-library-required-field
              export
              'name
              "primitive export"))
            (primitive
             (primitive-library-required-field
              export
              'primitive
              "primitive export"))
            (arity
             (primitive-library-required-field
              export
              'arity
              "primitive export")))
        (if (not (library-symbol? name))
            (eval-error "primitive export name must be a symbol" name))
        (if (not (library-symbol? primitive))
            (eval-error
             "primitive export implementation must be a symbol"
             primitive))
        (if (not (and (pair? arity)
                      (= (length arity) 2)
                      (integer? (car arity))
                      (exact? (car arity))
                      (>= (car arity) 0)
                      (or (not (cadr arity))
                          (and (integer? (cadr arity))
                               (exact? (cadr arity))
                               (>= (cadr arity) 0)))
                      (or (not (cadr arity))
                          (<= (car arity) (cadr arity)))))
            (eval-error
             "primitive export arity must be (minimum maximum)"
             name))
        (primitive-library-required-field
         export
         'effects
         "primitive export")
        (primitive-library-required-field
         export
         'capabilities
         "primitive export")
        (for-each
         (lambda (effect)
           (if (not (library-symbol? effect))
               (eval-error "primitive export effects must be symbols"
                           name)))
         (collection-entry-field export 'effects '()))
        (for-each
         (lambda (capability)
           (if (not (library-symbol? capability))
               (eval-error
                "primitive export capabilities must be symbols"
                name)))
         (collection-entry-field export 'capabilities '()))
        #t))

    (define (validate-primitive-library-declaration declaration)
      "Validate and return primitive-library DECLARATION."
      (if (not (library-symbol-eq? (collection-entry-field declaration 'kind
        #f)
                    'primitive-library))
          (eval-error
           "primitive-library declaration must have kind primitive-library"
           (collection-entry-field declaration 'name #f)))
      (if (not (library-symbol-eq? (collection-entry-field declaration
        'source-kind #f)
                    'primitive))
          (eval-error
           "primitive-library declaration must have source-kind primitive-libr\
ary"
           (collection-entry-field declaration 'name #f)))
      (let ((name (primitive-library-required-field
                   declaration
                   'name
                   "primitive-library declaration"))
            (owner (primitive-library-required-field
                    declaration
                    'owner
                    "primitive-library declaration"))
            (provider (primitive-library-required-field
                       declaration
                       'provider
                       "primitive-library declaration"))
            (visibility (primitive-library-required-field
                         declaration
                         'visibility
                         "primitive-library declaration"))
            (layer (primitive-library-required-field
                    declaration
                    'layer
                    "primitive-library declaration"))
            (implementation-id (primitive-library-required-field
                                declaration
                                'implementation-id
                                "primitive-library declaration"))
            (implementation-resolver
             (primitive-library-required-field
              declaration
              'implementation-resolver
              "primitive-library declaration"))
            (exports (primitive-library-required-field
                      declaration
                      'exports
                      "primitive-library declaration"))
            (primitive-exports
             (primitive-library-required-field
              declaration
              'primitive-exports
              "primitive-library declaration")))
        (if (not (and (or (string? name)
                          (proper-library-name? name))
                      (library-symbol? owner)
                      (library-symbol? provider)
                      (library-symbol? visibility)
                      (library-symbol? layer)
                      (library-symbol? implementation-id)
                      (not (null? implementation-resolver))))
            (eval-error
             "primitive-library declaration has invalid identity metadata"
             name))
        (if (or (null? exports)
                (not (let loop ((rest exports))
                       (cond
                        ((null? rest) #t)
                        ((library-symbol? (car rest)) (loop (cdr rest)))
                        (else #f)))))
            (eval-error
             "primitive-library declaration must declare exported names"
             name))
        (if (null? primitive-exports)
            (eval-error
             "primitive-library declaration must declare primitive exports"
             name))
        (let loop ((rest primitive-exports) (names '()))
          (if (not (null? rest))
              (begin
                (validate-primitive-library-export
                 (car rest)
                 declaration)
                (let ((export-name
                       (collection-entry-field (car rest) 'name #f)))
                  (if (library-memq export-name names)
                      (eval-error
                       "duplicate primitive export in declaration"
                       export-name))
                  (loop (cdr rest) (cons export-name names))))
              (begin
                (for-each
                 (lambda (export)
                   (if (not (library-memq export names))
                       (eval-error
                        "primitive-library export lacks primitive metadata"
                        export)))
                 exports)
                (for-each
                 (lambda (export)
                   (if (not (library-memq export exports))
                       (eval-error
                        "primitive-library primitive metadata is not exported"
                        export)))
                 names)))))
      declaration)

    (define (primitive-library-declaration? entry)
      "Report whether ENTRY contains provider-owned primitive metadata."
      (not (null? (collection-entry-field entry 'primitive-exports '()))))

    (define (primitive-library-declaration-specs declaration)
      "Materialize primitive specs from primitive-library DECLARATION."
      (let ((validated
             (validate-primitive-library-declaration declaration)))
        (map
         (lambda (export)
           (let ((arity (collection-entry-field export 'arity '())))
             (library-primitive-spec
              (collection-entry-field export 'name #f)
              (collection-entry-field export 'primitive #f)
              (car arity)
              (cadr arity))))
         (collection-entry-field validated 'primitive-exports '()))))

    (define (register-r5rs-library! key context environment)
      "Register `(scheme r5rs)' with R5RS aliases for exact/inexact conversion\
."
      (if (not (library-registry-ref context key))
          (let* ((base-library
                  (resolve-library scheme-base-library-key
                                   context
                                   environment))
                 (base-exports (library-exports base-library))
                 (inexact-binding
                  (or (find-library-export 'inexact base-exports)
                      (eval-error "R5RS inexact alias missing")))
                 (exact-binding
                  (or (find-library-export 'exact base-exports)
                      (eval-error "R5RS exact alias missing")))
                 (exports
                  (append
                   base-exports
                   (list
                    (library-binding-with-name
                     inexact-binding
                     'exact->inexact)
                    (library-binding-with-name
                     exact-binding
                     'inexact->exact)))))
            (library-registry-set!
             context
             key
             (make-library
              key
              key
              exports
              (library-value-environment base-library)
              (library-syntax-environment base-library))))))

    (define (manifest-primitive-implementation-specs entry)
      "Return primitive specs for manifest ENTRY, or #f when unavailable."
      (if (primitive-library-declaration? entry)
          (primitive-library-declaration-specs entry)
          #f))

    (define (manifest-implementation-available? entry)
      "Report whether manifest ENTRY has an implementation on this host."
      (let ((kind (collection-entry-field entry 'source-kind #f)))
        (cond
         ((consent-native-library-ref
           (collection-entry-field entry 'name #f))
          #t)
         ((library-symbol-eq? kind 'primitive)
          (guard (condition (else #f))
            (and (manifest-primitive-implementation-specs entry) #t)))
         ((library-symbol-eq? kind 'derived)
          (library-symbol-eq? (collection-entry-field entry 'implementation-id
            #f)
               'scheme-r5rs))
         (else #f))))

    (define (manifest-filter-primitive-specs entry primitive-specs)
      "Return PRIMITIVE-SPECS reduced to manifest ENTRY exports."
      (let ((exports (collection-entry-field entry 'exports '())))
        (if (null? exports)
            primitive-specs
            (let loop ((rest primitive-specs) (result '()))
              (cond
               ((null? rest) (reverse result))
               ((library-memq (car (car rest)) exports)
                (loop (cdr rest) (cons (car rest) result)))
               (else
                (loop (cdr rest) result)))))))

    (define (manifest-exported-primitive-specs entry)
      "Return primitive specs for ENTRY after applying manifest exports."
      (let ((primitive-specs
             (manifest-primitive-implementation-specs entry)))
        (if primitive-specs
            (manifest-filter-primitive-specs entry primitive-specs)
            (eval-error
             "manifest primitive library lacks provider declaration"
             (collection-entry-field entry 'name #f)))))

    (define (manifest-library-routable? entry)
      "Report whether manifest ENTRY describes an import route."
      (and entry
           (let ((kind (collection-entry-field entry 'source-kind #f)))
             (or (collection-entry-field entry 'target #f)
                 (collection-entry-field entry 'source-file #f)
                 (library-symbol-eq? kind 'base-snapshot)
                 (and (library-memq kind '(primitive derived))
                      (manifest-implementation-available? entry))))))

    (define (finish-manifest-library-registration! entry context)
      "Apply manifest overlays and export filtering to registered ENTRY."
      "This step is shared by interpreted and compiled realizations of a"
      "portable library so compilation cannot change its public semantics."
      (let ((key (collection-entry-field entry 'name #f))
            (exports-declared? (manifest-entry-exports-declared? entry))
            (exports (collection-entry-field entry 'exports '()))
            (overlay-library
             (collection-entry-field entry 'primitive-overlay-library #f)))
        (if (and overlay-library
                 (library-registry-ref context key))
            (let ((overlay-entry
                   (library-collection-manifest-entry overlay-library)))
              (if (not overlay-entry)
                  (eval-error
                   "manifest primitive overlay library is not declared"
                   overlay-library))
              (register-library-primitive-bindings!
               key
               (manifest-exported-primitive-specs overlay-entry)
               context)))
        (if exports-declared?
            (let ((library (library-registry-ref context key)))
              (if (not library)
                  (eval-error
                   "manifest source library registered a different name"
                   key))
              (library-registry-set!
               context
               key
               (make-library
                (library-name library)
                (library-key library)
                (filter-library-exports
                 (library-exports library)
                 exports
                 key)
                (library-value-environment library)
                (library-syntax-environment library)))))))

    (define (register-manifest-source-library! entry context environment)
      "Register source library described by manifest ENTRY."
      (let* ((key (collection-entry-field entry 'name #f))
             (source-file (collection-entry-field entry 'source-file #f))
             (root (collection-entry-field entry 'root #f))
             (shared-immutable?
              (shared-immutable-source-library-entry? entry))
             (cache-key
              (shared-immutable-source-library-key entry context)))
        (if (not source-file)
            (eval-error "manifest source library has no source-file" key))
        (if (not (library-registry-ref context key))
            (let ((cached
                   (shared-immutable-source-library-ref cache-key)))
              (if cached
                  (begin
                    (shared-immutable-source-library-charge-costs!
                     context (cadr cached) (third cached))
                    (library-registry-set! context key (car cached)))
                  (let ((steps-before (context-steps context))
                        (value-nodes-before (context-value-nodes context)))
                    (register-source-library!
                     (manifest-source-library-source source-file key root)
                     context
                     environment
                     (not shared-immutable?))
                    (finish-manifest-library-registration! entry context)
                    (shared-immutable-source-library-set!
                     cache-key
                     (library-registry-ref context key)
                     (- (context-steps context) steps-before)
                     (- (context-value-nodes context)
                        value-nodes-before))))))
        ;; A cached immutable library was already normalized before it entered
        ;; the process cache. Ordinary source libraries still finish here.
        (if (not cache-key)
            (finish-manifest-library-registration! entry context))))

    (define (register-manifest-native-library! entry context)
      "Register compiled realization of portable manifest ENTRY."
      (let* ((key (collection-entry-field entry 'name #f))
             (bindings (consent-native-library-ref key)))
        (if (not bindings)
            (eval-error "manifest library has no compiled realization" key))
        (register-native-library! key bindings context)
        (finish-manifest-library-registration! entry context)))

    (define (register-manifest-implementation-library! entry context
      environment)
      "Register primitive or derived library described by manifest ENTRY."
      (let ((key (collection-entry-field entry 'name #f))
            (native-bindings
             (consent-native-library-ref
              (collection-entry-field entry 'name #f))))
        (cond
         (native-bindings
          (register-manifest-native-library! entry context))
         ((library-symbol-eq? (collection-entry-field entry 'source-kind #f)
               'primitive)
          (register-primitive-library!
           key
           (manifest-exported-primitive-specs entry)
           context))
         ((and (library-symbol-eq? (collection-entry-field entry 'source-kind
           #f)
                    'derived)
               (library-symbol-eq? (collection-entry-field entry
                 'implementation-id #f)
                    'scheme-r5rs))
          (register-r5rs-library! key context environment))
        (else
          (eval-error
           "manifest library has no provider declaration or derived route"
           key)))))

    (define (library-available? name context environment)
      "Report whether NAME is a known or already registered library."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to test for availability."))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry and host grant are"
             "consulted.")))
         (environment (type environment)
          (description
            ("Environment available for resolving the library name."))))
        (returns (type boolean)
         (description
          ("#t when NAME names a known, registered, or host-loadable"
            "library, else #f.")))
        (effects state-read error))
      (let* ((key (library-name-key name))
             (entry (consent-library-catalog-entry key)))
        (and
         (or (not (library-visibility-internal?
                   (if entry
                       (library-catalog-field
                        entry
                        'visibility
                        (library-visibility key))
                       (library-visibility key))))
             (library-internal-import-allowed? context))
         (or (not entry)
             (library-entry-available? entry))
         (or (manifest-library-routable? entry)
             (and (library-registry-ref context key) #t)))))

    (define (resolve-library name context environment)
      "Resolve NAME to a library, registering lazy standard libraries as neede\
d."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to resolve to a registered library."))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry receives lazily"
             "registered libraries.")))
         (environment (type environment)
          (description
            ("Environment used when building or registering the library."))))
        (returns (type library)
         (description "The resolved library object for NAME."))
        (effects state-read state-write error))
      (let* ((key (library-name-key name))
             (entry (consent-library-catalog-entry key)))
        (ensure-library-entry-import-allowed key entry context)
        (if (and entry (not (library-entry-available? entry)))
            (eval-error "optional library is unavailable on this host" key))
        (if (not (library-registry-ref context key))
            (cond
             ((not entry) #f)
             ((consent-native-library-ref key)
              (register-manifest-native-library! entry context))
             ((collection-entry-field entry 'target #f)
              (register-library-alias!
               (manifest-library-alias-spec entry)
               context
               environment))
             ((library-symbol-eq? (collection-entry-field entry 'source-kind
               #f)
                   'base-snapshot)
              (register-scheme-base-library! context environment))
             ((collection-entry-field entry 'source-file #f)
              (register-manifest-source-library! entry context environment))
             ((library-memq (collection-entry-field entry 'source-kind #f)
                    '(primitive derived))
              (register-manifest-implementation-library!
               entry
               context
               environment))
             (else
              (eval-error
               "library has no manifest registration strategy"
               key))))
        (or (library-registry-ref context key)
            (eval-error "unknown library" key))))

    (define (find-import-binding name bindings)
      "Return NAME's import binding from BINDINGS, or #f."
      (cond
       ((null? bindings) #f)
       ((library-symbol-eq? name (library-binding-name (car bindings))) (car
         bindings))
       (else (find-import-binding name (cdr bindings)))))

    (define (ensure-import-names-present names bindings description)
      "Reject import modifiers naming exports that are absent from BINDINGS."
      (for-each
       (lambda (name)
         (if (not (find-import-binding name bindings))
             (eval-error
              (string-append description " import name not found")
              name)))
       names))

    (define (ensure-compatible-import-bindings bindings)
      "Merge duplicate compatible imports and reject conflicting imports."
      #((parameters
         (bindings (type list)
          (description
            ("List of import library bindings to deduplicate and check."))))
        (returns (type list)
         (description
           ("A list of bindings with compatible duplicates merged.")))
        (effects error))
      (let loop ((rest bindings) (seen '()) (result '()))
        (if (null? rest)
            (reverse result)
            (let* ((binding (car rest))
                   (name (library-binding-name binding))
                   (previous (library-assq name seen)))
              (cond
               ((not previous)
                (loop (cdr rest)
                      (cons (cons name binding) seen)
                      (cons binding result)))
               ((same-library-binding? (cdr previous) binding)
                (loop (cdr rest) seen result))
               (else
                (eval-error
                 "conflicting imports for identifier"
                 name)))))))

    (define (import-modifier-identifiers forms description)
      "Validate import modifier operands as symbols."
      (map (lambda (form) (expect-symbol form description)) forms))

    (define (resolve-import-set import-set context environment)
      "Resolve an import set, applying only/except/prefix/rename modifiers."
      (cond
       ((proper-library-name? import-set)
        (library-exports
         (resolve-library import-set context environment)))
       ((pair? import-set)
        (let* ((parts (proper-list-elements import-set "import set"))
               (operator (car parts)))
          (cond
           ((identifier-named? operator 'only)
            (if (< (length parts) 2)
                (eval-error "only import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (names
                    (import-modifier-identifiers (cddr parts) "only")))
              (ensure-import-names-present names bindings "only")
              (let loop ((rest bindings) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((library-memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) (cons (car rest) result)))
                 (else (loop (cdr rest) result))))))
           ((identifier-named? operator 'except)
            (if (< (length parts) 2)
                (eval-error "except import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (names
                    (import-modifier-identifiers (cddr parts) "except")))
              (ensure-import-names-present names bindings "except")
              (let loop ((rest bindings) (result '()))
                (cond
                 ((null? rest) (reverse result))
                 ((library-memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) result))
                 (else (loop (cdr rest) (cons (car rest) result)))))))
           ((identifier-named? operator 'prefix)
            (if (not (= (length parts) 3))
                (eval-error
                 "prefix import set requires an import set and prefix"))
            (let ((prefix
                   (library-symbol-name
                    (expect-symbol (third parts) "prefix identifier"))))
              (map
               (lambda (binding)
                 (library-binding-with-name
                 binding
                  (consent-intern-symbol
                   (context-symbol-table context)
                   (string-append
                    prefix
                    (library-symbol-name
                     (library-binding-name binding))))))
               (resolve-import-set (second parts) context environment))))
           ((identifier-named? operator 'rename)
            (if (< (length parts) 2)
                (eval-error "rename import set requires an import set"))
            (let* ((bindings
                    (resolve-import-set (second parts) context environment))
                   (renames
                    (map
                     (lambda (rename-form)
                       (let ((rename-parts
                              (proper-list-elements
                               rename-form
                               "rename pair")))
                         (if (not (= (length rename-parts) 2))
                             (eval-error
                              "rename pair requires old and new identifiers"))
                         (cons
                          (expect-symbol
                           (car rename-parts)
                           "rename old identifier")
                          (expect-symbol
                           (second rename-parts)
                           "rename new identifier"))))
                     (cddr parts))))
              (ensure-import-names-present (map car renames)
                                           bindings
                                           "rename")
              (map
               (lambda (binding)
                 (let ((rename
                        (library-assq (library-binding-name binding) renames)))
                   (if rename
                       (library-binding-with-name binding (cdr rename))
                       binding)))
               bindings)))
           (else
            (eval-error "invalid import set" import-set)))))
       (else
        (eval-error "invalid import set" import-set))))

    (define (install-imported-binding! binding value-environment
                                       syntax-environment context)
      "Install one imported value or syntax binding into the target frames."
      (let ((name
             (consent-intern-symbol
              (context-symbol-table context)
              (library-symbol-name (library-binding-name binding))))
            (kind (library-binding-kind binding))
            (object (library-binding-object binding))
            (binding-library-key (library-binding-library-key binding)))
        (cond
         ((library-symbol-eq? kind 'value)
          (let ((existing (frame-cell value-environment name)))
            (cond
             ((not existing)
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((library-datum-equal? binding-library-key
               scheme-base-library-key)
              ;; Repeated `(scheme base)' imports are common while source
              ;; libraries bootstrap; reinstalling the same base name is
              ;; harmless and keeps import-set handling small.
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((library-symbol-eq? existing object))
             (else
              (eval-error "conflicting import for identifier" name))))
          (if (not (library-memq name (environment-imported-names
            value-environment)))
              (set-environment-imported-names!
               value-environment
               (cons name (environment-imported-names value-environment)))))
         ((library-symbol-eq? kind 'syntax)
          (let ((existing (current-syntax-binding syntax-environment name)))
            (cond
             ((or (not existing)
                  (library-datum-equal? binding-library-key
                    scheme-base-library-key))
              (set-syntax-environment-frame!
               syntax-environment
               (cons (cons name object)
                     (syntax-environment-frame syntax-environment))))
             ((library-symbol-eq? existing object))
             (else
              (eval-error "conflicting syntax import for identifier" name))))
          (if (not (library-memq name
                         (syntax-environment-imported-names
                          syntax-environment)))
              (set-syntax-environment-imported-names!
               syntax-environment
               (cons name
                     (syntax-environment-imported-names
                      syntax-environment)))))
         (else
          (eval-error "unsupported library binding kind" kind)))))

    (define (install-import-set! import-set value-environment
                                 syntax-environment context)
      "Resolve IMPORT-SET and install all compatible imported bindings."
      (for-each
       (lambda (binding)
         (install-imported-binding! binding
                                    value-environment
                                    syntax-environment
                                    context))
       (ensure-compatible-import-bindings
        (resolve-import-set import-set context value-environment))))

    (define (eval-import form environment context)
      "Evaluate an import declaration into the active value and syntax frames.\
"
      #((parameters
         (form (type pair)
          (description
            ("Import declaration form whose import sets are installed.")))
         (environment (type environment)
          (description
            ("Value environment receiving the imported value bindings.")))
         (context (type eval-context)
          (description
           ("Evaluation context whose syntax environment and registry"
             "are used."))))
        (returns .
          ("The unspecified value after installing every import set."))
        (effects state-read state-write error))
      (let ((parts (proper-list-elements form "import declaration")))
        (if (< (length parts) 2)
            (eval-error "import requires at least one import set"))
        (for-each
         (lambda (import-set)
           (install-import-set!
            import-set
            environment
            (context-syntax-environment context)
            context))
         (cdr parts))
        consent-unspecified))

    (define (export-specs forms)
      "Parse export clauses into internal-name/external-name pairs."
      #((parameters
         (forms (type list)
          (description
            ("List of export clause forms (identifiers or rename forms)."))))
        (returns (type pair)
         (description
          ("A list of internal-name/external-name pairs in declaration"
            "order.")))
        (effects error))
      (let loop ((rest forms) (specs '()))
        (if (null? rest)
            (reverse specs)
            (let ((form (car rest)))
              (cond
               ((identifier-datum? form)
                (let ((name (expect-symbol form "export identifier")))
                  (loop (cdr rest) (cons (cons name name) specs))))
               ((form-named? form 'rename)
                (let ((parts (proper-list-elements form "export rename")))
                  (if (not (= (length parts) 3))
                      (eval-error
                       "export rename requires internal and external identifie\
rs"))
                  (loop
                   (cdr rest)
                   (cons
                    (cons
                     (expect-symbol
                      (second parts)
                      "export internal identifier")
                     (expect-symbol
                      (third parts)
                      "export external identifier"))
                    specs))))
               (else
                (eval-error "invalid export spec" form)))))))

    (define (feature-requirement-satisfied? requirement context environment)
      "Report whether a cond-expand feature requirement is satisfied."
      (cond
       ((identifier-datum? requirement)
        (library-memq (identifier-datum-name requirement) '(r7rs srfi-0
          consent)))
       ((pair? requirement)
        (let* ((parts (proper-list-elements requirement "feature requirement"))
               (operator (car parts)))
          (cond
           ((identifier-named? operator 'library)
            (if (not (= (length parts) 2))
                (eval-error
                 "library feature requirement requires one library name"))
            (library-available? (second parts) context environment))
           ((identifier-named? operator 'and)
            (let loop ((rest (cdr parts)))
              (or (null? rest)
                  (and (feature-requirement-satisfied?
                        (car rest)
                        context
                        environment)
                       (loop (cdr rest))))))
           ((identifier-named? operator 'or)
            (let loop ((rest (cdr parts)))
              (and (not (null? rest))
                   (or (feature-requirement-satisfied?
                        (car rest)
                        context
                        environment)
                       (loop (cdr rest))))))
           ((identifier-named? operator 'not)
            (if (not (= (length parts) 2))
                (eval-error
                 "not feature requirement requires one nested requirement"))
            (not
             (feature-requirement-satisfied?
              (second parts)
              context
              environment)))
           (else #f))))
       (else #f)))

    (define (expand-library-cond-expand clauses context environment)
      "Select declarations from the first satisfied library cond-expand clause\
."
      (let loop ((rest clauses))
        (if (null? rest)
            (eval-error "unfulfilled library cond-expand")
            (let* ((parts (proper-list-elements
                           (car rest)
                           "cond-expand clause"))
                   (requirement (car parts)))
              (if (or (identifier-named? requirement 'else)
                      (feature-requirement-satisfied?
                       requirement context environment))
                  (cdr parts)
                  (loop (cdr rest)))))))

    (define (expand-library-declaration declaration context environment)
      "Expand library declaration wrappers such as cond-expand and includes."
      (cond
       ((form-named? declaration 'cond-expand)
        (apply append
               (map
                (lambda (nested)
                  (expand-library-declaration nested context environment))
                (expand-library-cond-expand
                 (cdr (proper-list-elements
                       declaration
                       "library cond-expand"))
                 context
                 environment))))
       ((form-named? declaration 'include-library-declarations)
        (expand-include-library-declarations
         declaration
         context
         environment))
       (else
        (list declaration))))

    (define (include-filenames declaration)
      "Return string literal filenames from an include-style declaration."
      (let* ((parts (proper-list-elements declaration "include declaration"))
             (operator (identifier-datum-name (car parts))))
        (if (null? (cdr parts))
            (eval-error "include requires at least one filename" operator))
        (map
         (lambda (filename)
           (if (not (string? filename))
               (eval-error "include filename must be a string literal"
                           operator))
           filename)
         (cdr parts))))

    (define (string-prefix? prefix string)
      "Test whether TEXT begins with PREFIX."
      (let ((prefix-length (string-length prefix))
            (string-length-value (string-length string)))
        (and (<= prefix-length string-length-value)
             (let loop ((index 0))
               (or (= index prefix-length)
                   (and (char=? (string-ref prefix index)
                                (string-ref string index))
                        (loop (+ index 1))))))))

    (define (strip-trailing-slash path)
      "Remove a single trailing slash from PATH for policy-prefix checks."
      (if (and (> (string-length path) 0)
               (char=? (string-ref path (- (string-length path) 1)) #\/))
          (substring path 0 (- (string-length path) 1))
          path))

    (define (path-policy-allows-file? path allowed-paths)
      "Report whether PATH is exactly allowed or inside an allowed directory."
      #((parameters
         (path (type list)
          (description "File path to test against the allow-list."))
         (allowed-paths (type string)
          (description "List of allowed file or directory path strings.")))
        (returns (type boolean)
         (description
          ("#t when PATH equals or sits under an allowed path, else"
            "#f.")))
        (effects pure))
      (let loop ((rest allowed-paths))
        (and (not (null? rest))
             (let* ((allowed (strip-trailing-slash (car rest)))
                    (allowed-directory (string-append allowed "/")))
               (or (string=? path allowed)
                   (string-prefix? allowed-directory path)
                   (loop (cdr rest)))))))

    (define (include-policy-allows-file? path context)
      "Report whether PATH satisfies the current include allow-list policy."
      (path-policy-allows-file? path (context-include-paths context)))

    (define (resolve-include-file filename context operation binding)
      "Resolve FILENAME against the include directory and enforce file policy.\
"
      (let* ((authorization
              (authorize-file-capability
               filename
               context
               operation
               binding
               (context-include-paths context)))
             (path (file-authorization-path authorization)))
        (if (not (file-exists? path))
            (begin
              (audit-file-capability-result!
               context
               authorization
               "include file is not readable"
               #t)
              (eval-error "include file is not readable" filename)))
        (audit-file-capability-result! context authorization 'read #f)
        path))

    (define (path-directory path)
      "Return PATH's directory component without the trailing slash."
      #((parameters
         (path (type string)
          (description "File path whose directory component is extracted.")))
        (returns (type string)
         (description
          ("The directory portion of PATH without a trailing slash, or"
            "the empty string.")))
        (effects pure))
      (let loop ((index (- (string-length path) 1)))
        (cond
         ((< index 0) "")
         ((char=? (string-ref path index) #\/)
          (substring path 0 index))
         (else (loop (- index 1))))))

    (define (read-file-string path)
      "Read PATH into a string using the Scheme file API."
      #((parameters
         (path (type string)
          (description "Filesystem path of the file to read.")))
        (returns (type string)
         (description
           ("A string holding the entire contents of the file at PATH.")))
        (effects state-read))
      (call-with-input-file
       path
       (lambda (port)
         (let loop ((chars '()))
           (let ((char (read-char port)))
             (if (eof-object? char)
                 (list->string (reverse chars))
                 (loop (cons char chars))))))))

    (define (with-include-directory context directory thunk)
      "Run THUNK with CONTEXT's include directory temporarily set."
      #((parameters
         (context (type eval-context)
          (description
           ("Evaluation context whose include directory is swapped.")))
         (directory (type string)
          (description
           ("Directory to install as the include directory during"
             "THUNK.")))
         (thunk (type procedure)
          (description
           ("Zero-argument procedure run with the temporary include"
             "directory."))))
        (returns . "The value produced by THUNK.")
        (effects state-write host-eval))
      (let ((previous-directory (context-include-directory context)))
        (dynamic-wind
          (lambda ()
            (set-context-include-directory!
             context
             (normalize-include-directory directory)))
          thunk
          (lambda ()
            (set-context-include-directory!
             context
             previous-directory)))))

    (define (read-include-file-forms filename context fold-case? operation)
      "Read and parse all forms from an include file, returning forms and dire\
ctory."
      (let* ((path (resolve-include-file
                    filename
                    context
                    operation
                    (if (library-symbol-eq? operation 'include-ci)
                        "include-ci"
                        (if (library-symbol-eq? operation 'library-source)
                            "include-library-declarations"
                            "include"))))
             (source (read-file-string path)))
        (cons
         (consent-read-all
          (if fold-case?
              (string-append "#!fold-case\n" source)
              source)
          (context-reader-options context))
         (path-directory path))))

    (define (library-include-body-forms declaration context fold-case?)
      "Return all body forms read by an include or include-ci declaration."
      (apply append
             (map (lambda (filename)
                    (car (read-include-file-forms
                          filename
                          context
                          fold-case?
                          (if fold-case? 'include-ci 'include))))
                  (include-filenames declaration))))

    (define (expand-include-library-declarations declaration context
                                                 environment)
      "Read include-library-declarations files and expand their declarations."
      (apply
       append
       (map
        (lambda (filename)
          (let* ((read-result
                  (read-include-file-forms
                   filename
                   context
                   #f
                   'library-source))
                 (forms (car read-result))
                 (directory (cdr read-result)))
            (with-include-directory
             context
             directory
             (lambda ()
               (apply
                append
                (map
                 (lambda (nested)
                   (expand-library-declaration
                    nested
                    context
                    environment))
                 forms))))))
        (include-filenames declaration))))

    (define (library-export-binding spec library-key value-environment
                                    syntax-environment)
      "Resolve one export spec to a value or syntax library binding."
      (let* ((internal-name (car spec))
             (external-name (cdr spec))
             (cell (environment-cell value-environment internal-name))
             (syntax-binding
              (library-syntax-environment-ref syntax-environment
                internal-name)))
        (cond
         ((and cell syntax-binding)
          (eval-error
           "export identifier has both value and syntax bindings"
           internal-name))
         (cell
          (make-library-binding external-name 'value cell library-key))
         (syntax-binding
          (make-library-binding external-name
                                'syntax
                                syntax-binding
                                library-key))
         (else
          (eval-error "exported identifier is not bound" internal-name)))))

    (define (library-exports-from-specs specs library-key value-environment
                                        syntax-environment)
      "Build checked library exports from parsed export specs."
      (ensure-distinct-names (map cdr specs) "library exports")
      (ensure-compatible-import-bindings
       (map (lambda (spec)
              (library-export-binding spec
                                      library-key
                                      value-environment
                                      syntax-environment))
            specs)))

    (define (eval-library-begin forms value-environment
                                syntax-environment context)
      "Evaluate library body forms under the library syntax environment."
      (library-with-syntax-environment
       context
       syntax-environment
       (lambda ()
         (library-trampoline
          (make-sequence forms #t)
          value-environment
          context))))

    (define (eval-define-library form environment context)
      "Evaluate a define-library form and register its exported bindings."
      #((parameters
         (form (type pair)
          (description "define-library form to evaluate and register."))
         (environment (type environment)
          (description
           ("Environment used while expanding the library's"
             "declarations.")))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry receives the new"
             "library."))))
        (returns
         . ("The unspecified value after registering the defined"
            "library."))
        (effects state-read state-write host-eval error))
      (let ((parts (proper-list-elements form "define-library form")))
        (if (< (length parts) 2)
            (eval-error "define-library requires a library name"))
        (let ((name (second parts)))
          (if (not (proper-library-name? name))
              (eval-error "invalid library name" name))
          (let ((library-key (library-name-key name))
                (value-environment (consent-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment
                  #f)))
            (let loop ((raw-declarations (cddr parts))
                       (export-spec-list '()))
              (if (null? raw-declarations)
                  (begin
                    (library-registry-set!
                     context
                     library-key
                     (make-library
                      name
                      library-key
                      (library-exports-from-specs
                       export-spec-list
                       library-key
                       value-environment
                       syntax-environment)
                      value-environment
                      syntax-environment))
                    consent-unspecified)
                  (let declaration-loop
                      ((declarations
                        (expand-library-declaration
                         (car raw-declarations)
                         context
                         environment))
                       (exports export-spec-list))
                    (if (null? declarations)
                        (loop (cdr raw-declarations) exports)
                        (let* ((declaration (car declarations))
                               (declaration-parts
                                (proper-list-elements
                                 declaration
                                 "library declaration"))
                               (operator (car declaration-parts)))
                          ;; `cond-expand' and include-library-declarations are
                          ;; flattened before this dispatch; only core library
                          ;; declarations should reach this point.
                          (cond
                           ((identifier-named? operator 'export)
                            (declaration-loop
                             (cdr declarations)
                             (append exports
                                     (export-specs
                                      (cdr declaration-parts)))))
                           ((identifier-named? operator 'import)
                            (library-with-syntax-environment
                             context
                             syntax-environment
                             (lambda ()
                               (eval-import declaration
                                            value-environment
                                            context)))
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'begin)
                            (eval-library-begin
                             (cdr declaration-parts)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'include)
                            (eval-library-begin
                             (library-include-body-forms
                              declaration
                              context
                              #f)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named? operator 'include-ci)
                            (eval-library-begin
                             (library-include-body-forms
                              declaration
                              context
                              #t)
                             value-environment
                             syntax-environment
                             context)
                            (declaration-loop (cdr declarations) exports))
                           ((identifier-named?
                             operator
                             'include-library-declarations)
                            (eval-error
                             "include-library-declarations must expand before \
evaluation"
                             operator))
                           (else
                            (eval-error
                             "unsupported library declaration"
                             declaration))))))))))))

    ))
