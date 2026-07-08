;;; Portable Consent Scheme library resolver support.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns source-library discovery, import-set resolution, and
;;; define-library evaluation without importing the evaluator module.

(define-library (consent library)
  (export consent-standard-source-library-specs
          consent-stdlib-source-library-specs
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
          consent-install-library-backend!
          consent-native-argument-value
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
          (consent reader)
          (consent runtime)
          (consent base))
  (begin

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
      (set! library-make-empty-syntax-environment make-empty-syntax-environment)
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

    ;; Alias specs are alists so new optional fields remain backwards-compatible.
    (define (library-alias-field spec field)
      "Return FIELD from alias SPEC, or #f when absent."
      (let ((entry (assq field spec)))
        (if entry (cdr entry) #f)))

    ;; Cache selected source path and contents by manifest source-file/key pair.
    (define manifest-source-library-source-cache '())

    ;; Bootstrap file name for every configured manifest root.
    (define library-manifest-index-file "manifest.sld")

    ;; Cache metadata read from configured collection manifests.
    (define library-collection-manifest-cache #f)

    ;; Trusted runtime source libraries may import private primitive backing
    ;; libraries while being loaded without making those libraries ordinary
    ;; user imports.
    (define source-library-internal-import-depth 0)

    ;; Cache manifest-backed catalog entries after the evaluator backend is live.
    (define library-catalog-cache #f)

    ;; Ad-hoc manifest catalog sources are metadata only and have highest
    ;; precedence in discovery.
    (define library-catalog-ad-hoc-manifests '())

    ;; Manifest root catalog sources are metadata only and follow ad-hoc inputs.
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
                     ((or (symbol? (car rest))
                          (and (integer? (car rest))
                               (exact? (car rest))
                               (>= (car rest) 0))
                          (and (consent-number? (car rest))
                               (eq? (consent-number-kind (car rest))
                                    'integer)
                               (eq? (consent-number-exactness (car rest))
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
       ((equal? key (caar alist)) (car alist))
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
                (if (member source-file seen)
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
      (let ((forms (consent-read-all source '((source-metadata . #f)))))
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
                        (equal? (library-name-key (second parts)) key)))
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
            (cadr (assq 'root (car roots)))
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
            (eval-error "manifest variable must be quoted" (list key variable)))
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
      (let ((forms (consent-read-all source '((source-metadata . #f)))))
        (if (not (= (length forms) 1))
            (eval-error
             (string-append description " must contain exactly one form")
             key))
        (let* ((form (car forms))
               (parts (proper-list-elements form description)))
          (if (not (and (>= (length parts) 2)
                        (identifier-named? (car parts) 'define-library)
                        (equal? (library-name-key (second parts)) key)))
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
       (cadr (assq 'manifest-source root-descriptor))
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

    (define (collection-manifest-symbol value description)
      "Return VALUE when it is a symbol."
      (if (symbol? value)
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
             (root (cadr (assq 'root root-descriptor)))
             (root-id (cadr (assq 'root-id root-descriptor)))
             (root-kind (cadr (assq 'root-kind root-descriptor)))
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
               (string-append root-id ":" (symbol->string collection))))))

    (define (collection-entry-field entry field default)
      "Return FIELD from collection ENTRY, or DEFAULT."
      (let ((cell (and entry (assq field entry))))
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
             ((eq? kind 'source-library) 'portable-source)
             ((eq? kind 'primitive-library) 'primitive)
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
          (if (eq? value sentinel)
              (eval-error "primitive export missing field" field)
              value))))

    (define (primitive-library-symbol-list value description)
      "Return VALUE as a list of symbols for primitive metadata."
      (let ((parts (proper-list-elements value description)))
        (for-each
         (lambda (part)
           (if (not (symbol? part))
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
        (if (not (symbol? name))
            (eval-error "primitive export name must be a symbol" name))
        (if (not (symbol? primitive))
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
             (eq? (consent-number-kind value) 'integer)
             (eq? (consent-number-exactness value) 'exact)
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
       ((or target (eq? source-kind 'alias)) 'library-alias)
       ((eq? source-kind 'primitive) 'primitive-library)
       (else 'library)))

    (define (manifest-api-version-default visibility target)
      "Return default api-version metadata for VISIBILITY and TARGET."
      (cond
       (target (list 'inherits target))
       ((or (eq? visibility 'internal-runtime)
            (eq? visibility 'internal-agent-primitive)
            (eq? visibility 'host-adapter))
        'internal)
       (else '(compat 0))))

    (define (manifest-source-version-default source-kind)
      "Return default source-version metadata for SOURCE-KIND."
      (if (or (eq? source-kind 'base-snapshot)
              (eq? source-kind 'primitive)
              (eq? source-kind 'derived))
          'runtime
          'unknown))

    (define (manifest-realization-default source-kind)
      "Return default realization metadata for SOURCE-KIND."
      (cond
       ((eq? source-kind 'portable-source) 'portable-source)
       ((eq? source-kind 'primitive) 'host-primitive)
       ((eq? source-kind 'alias) 'alias)
       ((eq? source-kind 'base-snapshot) 'runtime-snapshot)
       ((eq? source-kind 'derived) 'derived)
       ((eq? source-kind 'facade) 'shim)
       (source-kind source-kind)
       (else 'unknown)))

    (define (manifest-source-path source)
      "Return path from manifest SOURCE metadata, or #f."
      (and source
           (pair? source)
           (let ((parts (proper-list-elements source "manifest source")))
             (and (= (length parts) 2)
                  (eq? (car parts) 'path)
                  (string? (cadr parts))
                  (cadr parts)))))

    (define (manifest-source-implementation-id source)
      "Return implementation id from manifest SOURCE metadata, or #f."
      (and source
           (pair? source)
           (let ((parts (proper-list-elements source "manifest source")))
             (and (= (length parts) 2)
                  (eq? (car parts) 'implementation-id)
                  (collection-manifest-symbol
                   (cadr parts)
                   "manifest source implementation-id")))))

    (define (manifest-source-with-path source path)
      "Return SOURCE normalized to resolved PATH when SOURCE is a path datum."
      (if (and source path (pair? source))
          (let ((parts (proper-list-elements source "manifest source")))
            (if (and (= (length parts) 2) (eq? (car parts) 'path))
                (list 'path path)
                source))
          source))

    (define (manifest-source-default source source-file target implementation-id)
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
                     (eq? (car parts) 'summary)
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
        (if (and parts (eq? (car parts) 'library) (pair? (cdr parts)))
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
      (if (eq? status 'alias) 'alias 'public))

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
        (let ((cached (assoc/equal cache-key manifest-source-library-source-cache)))
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
      "Return catalog metadata parsed from collection manifest ENTRY and SPEC."
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
             (exports
              (let ((value (collection-manifest-field
                            entry 'exports exports-absent)))
                (if (eq? value exports-absent)
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
             (provenance
              (collection-manifest-field entry 'provenance #f))
             (canonical
              (collection-manifest-field
               entry
               'canonical
               (not (and target (eq? source-kind 'alias))))))
        (if (not (= schema-version manifest-schema-version))
            (eval-error
             "unsupported collection manifest schema-version"
             schema-version))
        (if (eq? exports exports-absent)
            (if (and target (eq? source-kind 'alias))
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
         (list 'exports exports)
         (list 'dependencies dependencies)
         (list 'effects effects)
         (list 'capabilities capabilities)
         (list 'documentation documentation)
         (list 'provenance provenance)
         (list 'canonical canonical)
         (list 'origin 'built-in-seed)
         (list 'source-id (collection-entry-field spec 'source-id #f))
         (list 'summary summary))))

    (define (library-collection-manifest-entries)
      "Return collection-manifest metadata for configured manifest roots."
      (let ((cache-key (library-manifest-root-cache-key)))
        (if (and library-collection-manifest-cache
                 (equal? (car library-collection-manifest-cache) cache-key))
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
         ((equal? key (collection-entry-field (car entries) 'name '()))
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
      (or (eq? visibility 'internal-runtime)
          (eq? visibility 'internal-agent-primitive)))

    (define (library-availability-condition-satisfied? condition)
      "Report whether manifest availability CONDITION is satisfied."
      (cond
       ((not condition) #t)
       ((and (pair? condition)
             (eq? (car condition) 'host)
             (eq? (cadr condition) 'emacs))
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
           ((not (null? (collection-entry-field manifest-entry 'exports '())))
            (collection-entry-field manifest-entry 'exports '()))
           ((collection-entry-field manifest-entry 'target #f)
            (library-catalog-export-names
             (collection-entry-field manifest-entry 'target #f)))
           ((library-catalog-source-backed? key)
            (source-library-export-names
             (library-catalog-source-form key)))
           ((equal? key scheme-base-library-key)
            (map (lambda (spec) (second (assq 'name spec)))
                 (consent-base-binding-specs)))
           (else
            (library-catalog-resolved-export-names key))))))

    (define (library-catalog-aliases key)
      "Return aliases that resolve to library KEY."
      (let loop ((entries (library-collection-manifest-entries))
                 (result '()))
        (cond
         ((null? entries) (reverse result))
         ((equal? key (collection-entry-field (car entries) 'target #f))
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
      (let ((cell (assq field entry)))
        (if cell (cadr cell) default)))

    (define (library-catalog-manifest-field fields field default)
      "Return FIELD's value from manifest FIELDS, or DEFAULT."
      (let ((cell (assq field fields)))
        (if cell (cadr cell) default)))

    (define (library-catalog-manifest-field-values fields field)
      "Return every value for FIELD from manifest FIELDS."
      (let ((cell (assq field fields)))
        (if cell (cdr cell) '())))

    (define (library-catalog-require-symbol value description)
      "Return VALUE when it is a symbol, else raise a catalog diagnostic error."
      (if (symbol? value)
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
           (if (not (symbol? part))
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
             "catalog entry must begin with manifest-entry or manifest-index-entry"
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
               (provenance
                (library-catalog-manifest-field fields 'provenance #f))
               (canonical
                (library-catalog-manifest-field
                 fields
                 'canonical
                 (not (and target (eq? source-kind 'alias))))))
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
           (list 'api-version api-version)
           (list 'source-version source-version)
           (list 'realization realization)
           (list 'source source)
           (list 'source-file source-file)
           (list 'aliases aliases)
           (list 'target target)
           (list 'exports exports)
           (list 'dependencies dependencies)
           (list 'effects effects)
           (list 'capabilities capabilities)
           (list 'documentation documentation)
           (list 'provenance provenance)
           (list 'canonical canonical)
           (list 'origin origin)
           (list 'source-id source-id)
           (list 'summary summary)))))

    (define (library-catalog-parse-manifest manifest origin source-id)
      "Validate MANIFEST and return catalog entries with ORIGIN and SOURCE-ID."
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
      "Return SOURCES with SOURCE-ID replaced by ENTRIES at highest precedence."
      (let loop ((rest sources) (result '()))
        (cond
         ((null? rest) (cons (cons source-id entries) (reverse result)))
         ((equal? source-id (caar rest))
          (append (reverse result)
                  (cons (cons source-id entries) (cdr rest))))
         (else (loop (cdr rest) (cons (car rest) result))))))

    (define (library-catalog-remove-source sources source-id)
      "Return (REMOVED? . SOURCES) after removing SOURCE-ID."
      (let loop ((rest sources) (result '()) (removed? #f))
        (cond
         ((null? rest) (cons removed? (reverse result)))
         ((equal? source-id (caar rest))
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
             (library-catalog-parse-manifest
              manifest
              'manifest-root
              root)))
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
         (list 'visibility (library-visibility key))
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
         (list 'source-file (library-catalog-source-file key))
         (list 'aliases
               (if manifest-entry
                   (collection-entry-field manifest-entry 'aliases '())
                   (library-catalog-aliases key)))
         (list 'target
               (or (collection-entry-field manifest-entry 'target #f)
                   #f))
         (list 'exports (library-catalog-export-names key))
         (list 'dependencies (library-catalog-dependencies key))
         (list 'effects (collection-entry-field manifest-entry 'effects #f))
         (list 'capabilities
               (collection-entry-field manifest-entry 'capabilities #f))
         (list 'documentation
               (collection-entry-field manifest-entry 'documentation #f))
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
      (let ((cell (assq field entry)))
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
      (if (not library-catalog-cache)
          (consent-library-catalog-entries))
      library-catalog-diagnostics)

    (define (library-catalog-name-part-text part)
      "Return PART as public library-name text."
      (cond
       ((symbol? part) (symbol->string part))
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
         ((library-catalog-text-match? (symbol->string (car rest)) needle) #t)
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
        (symbol->string (library-catalog-field entry 'category 'library))
        needle)
       (library-catalog-text-match?
        (symbol->string (library-catalog-field entry 'source-kind 'manifest))
        needle)
       (library-catalog-text-match?
        (symbol->string (library-catalog-field entry 'visibility 'public))
        needle)
       (library-catalog-text-match?
        (symbol->string (library-catalog-field entry 'status 'implemented))
        needle)
       (library-catalog-text-match?
        (symbol->string (library-catalog-field entry 'origin 'built-in-seed))
        needle)
       (library-catalog-text-match?
        (library-catalog-field entry 'source-file #f)
        needle)
       (let ((source-id (library-catalog-field entry 'source-id #f)))
         (library-catalog-text-match?
          (cond
           ((string? source-id) source-id)
           ((symbol? source-id) (symbol->string source-id))
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
       ((symbol? query) (symbol->string query))
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
      (if library-catalog-cache
          library-catalog-cache
          (let ((entries
                 (library-catalog-deduplicate
                  (library-catalog-candidate-entries))))
            (set! library-catalog-cache entries)
            entries)))

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
           ((equal? key (library-catalog-field (car entries) 'name '()))
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

    (define (consent-standard-source-library-specs)
      "Public metadata accessor for standard libraries backed by source files."
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed standard library.")))
        (effects state-read state-write))
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
                    "standard source library")))
            (list 'source-file (library-catalog-source-file key)))))
       (let loop ((entries (library-collection-manifest-entries))
                  (result '()))
         (cond
          ((null? entries) (reverse result))
          ((and (eq? (collection-entry-field
                      (car entries) 'category #f)
                     'standard)
                (eq? (collection-entry-field
                      (car entries) 'source-kind #f)
                     'portable-source))
           (loop (cdr entries) (cons (car entries) result)))
          (else (loop (cdr entries) result))))))

    (define (consent-stdlib-source-library-specs)
      "Public metadata accessor for stdlib libraries backed by source files."
      #((parameters)
        (returns (type list)
         (description
          ("A list of name, exports, and source-file metadata entries"
            "for each source-backed stdlib library.")))
        (effects state-read state-write))
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
                    "stdlib source library")))
            (list 'source-file (library-catalog-source-file key)))))
       (let loop ((entries (library-collection-manifest-entries))
                  (result '()))
         (cond
          ((null? entries) (reverse result))
          ((and (eq? (collection-entry-field
                      (car entries) 'category #f)
                     'stdlib)
                (eq? (collection-entry-field
                      (car entries) 'source-kind #f)
                     'portable-source))
           (loop (cdr entries) (cons (car entries) result)))
          (else (loop (cdr entries) result))))))

    (define (library-registry-ref context key)
      "Return the registered library for KEY in CONTEXT, or #f."
      #((parameters
         (context (type eval-context)
          (description ("Evaluation context whose library registry is searched.")))
         (key (type list)
          (description "Library registry key to look up.")))
        (returns (type (or library boolean))
         (description "The library registered under KEY, or #f when it is absent."))
        (effects state-read))
      (let ((cell (assoc/equal key (context-libraries context))))
        (if cell (cdr cell) #f)))

    (define (library-registry-set! context key library)
      "Store LIBRARY under KEY in CONTEXT's registry."
      #((parameters
         (context (type eval-context)
          (description ("Evaluation context whose library registry is updated.")))
         (key (type list)
          (description "Library registry key to associate with LIBRARY."))
         (library (type library)
          (description "Library object to store under KEY.")))
        (returns . ("An unspecified value after registering LIBRARY under KEY."))
        (effects state-write))
      (let replace ((rest (context-libraries context)) (prefix '()))
        (cond
         ((null? rest)
          (set-context-libraries!
           context
           (cons (cons key library) (context-libraries context))))
         ((equal? key (caar rest))
          (set-context-libraries!
           context
           (append (reverse prefix)
                   (cons (cons key library) (cdr rest)))))
         (else
          (replace (cdr rest) (cons (car rest) prefix))))))

    (define (current-syntax-binding syntax-environment name)
      "Return NAME's binding from SYNTAX-ENVIRONMENT's current frame only."
      (let ((cell (assq name (syntax-environment-frame syntax-environment))))
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
         (description ("#t when FORM is headed by the import identifier, else #f.")))
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
           (eq? (library-binding-kind left) (library-binding-kind right))
           (eq? (library-binding-object left)
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

    (define (register-source-library! source context environment)
      "Read and evaluate a define-library form from SOURCE."
      (dynamic-wind
        (lambda ()
          (set! source-library-internal-import-depth
                (+ source-library-internal-import-depth 1)))
        (lambda ()
          (let ((forms
                 (consent-read-all source (context-reader-options context))))
            (if (not (= (length forms) 1))
                (eval-error "source library must contain exactly one form"))
            (eval-define-library
             (car forms)
             environment
             context)))
        (lambda ()
          (set! source-library-internal-import-depth
                (- source-library-internal-import-depth 1)))))

    (define (native-callback-result value seen)
      "Convert an interpreted callback's result for native consumption."
      "Canonical number records become raw host numbers -- a custom resync"
      "strategy returns an offset the reader clamps with host arithmetic --"
      "and the interpreter's end-of-file record becomes the host end-of-file"
      "object a native input driver tests with eof-object?. Pairs and vectors"
      "are walked copy-on-write so untouched structure keeps its identity,"
      "and SEEN returns cyclic data unchanged on revisit."
      (cond
       ((consent-number? value)
        (let ((host (consent-number-value value)))
          (if (number? host) host value)))
       ((consent-eof-object? value)
        (eof-object))
       ((pair? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (head (native-callback-result (car value) next-seen))
                   (tail (native-callback-result (cdr value) next-seen)))
              (if (and (eq? head (car value)) (eq? tail (cdr value)))
                  value
                  (cons head tail)))))
       ((vector? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (length (vector-length value))
                   (converted
                    (let loop ((index 0) (acc '()) (changed #f))
                      (if (= index length)
                          (and changed (reverse acc))
                          (let* ((element (vector-ref value index))
                                 (next (native-callback-result
                                        element next-seen)))
                            (loop (+ index 1)
                                  (cons next acc)
                                  (or changed (not (eq? next element)))))))))
              (if converted (list->vector converted) value))))
       (else value)))

    (define (native-callback-shim value context)
      "Wrap interpreted callable VALUE as a host procedure applying it in"
      "CONTEXT. Callback arguments re-enter the Consent world through the"
      "shared host-datum bridge, so interpreted callbacks see canonical"
      "Consent numbers and preserved source-metadata structure instead of raw host"
      "runtime values leaking through the compiled boundary."
      "The closure's result crosses back under the callback result conversion"
      "(canonical records become raw host numbers), so native higher-order"
      "code can consume what the closure returns."
      (let ((applier (consent-native-applier-ref)))
        (lambda arguments
          (native-callback-result
           (applier value
                    (map (lambda (argument)
                           (native-result-value argument))
                         arguments)
                    context)
           '()))))

    ;; Context of the native call currently crossing the import boundary.
    ;; The native binding shim maintains it dynamically so callable arguments
    ;; applied by native higher-order code run in the calling program's
    ;; context.
    (define native-call-context #f)

    ;; Some internal-library exports operate on reader-owned Consent datums whose
    ;; identity must survive the native call boundary intact: source-metadata
    ;; accessors key off the original pair/vector/string object, and numeric
    ;; predicates should inspect canonical number records instead of a
    ;; host-unwrapped payload. Most other portable libraries still want the
    ;; ordinary host-facing scalar conversion.
    (define native-preserved-argument-bindings
      '((((consent macro) consent-syntax-source))
        (((consent reader)
          consent-datum-source
          consent-datum-source-set!
          consent-copy-datum-source!
          consent-datum->external
          consent-datum->external-bounded
          consent-number?
          consent-number-lexeme
          consent-number-exactness
          consent-number-radix
          consent-number-kind
          consent-number-value
          consent-number-zero?
          consent-number-negative?
          consent-number-abs
          consent-number->external))))

    ;; Accessors that intentionally publish a host scalar payload should keep
    ;; that surface instead of rewrapping the result back into a Consent number.
    (define native-host-result-bindings
      '((((consent reader) consent-number-value))))

    (define (native-binding-policy-member? table library-key name)
      "Report whether TABLE marks NAME in LIBRARY-KEY for special handling."
      (let loop ((rest table))
        (if (null? rest)
            #f
            (let ((entry (car rest)))
              (if (equal? (caar entry) library-key)
                  (memq name (cdar entry))
                  (loop (cdr rest)))))))

    (define (native-binding-argument-policy library-key name)
      "Return how NAME in LIBRARY-KEY should receive its arguments."
      (if (native-binding-policy-member?
           native-preserved-argument-bindings
           library-key
           name)
          'preserve
          'convert))

    (define (native-binding-result-policy library-key name)
      "Return how NAME in LIBRARY-KEY should publish its result."
      (if (native-binding-policy-member?
           native-host-result-bindings
           library-key
           name)
          'host
          'consent))

    (define (native-binding-argument library-key name argument context)
      "Bridge one ARGUMENT for NAME in LIBRARY-KEY into native code."
      (if (eq? (native-binding-argument-policy library-key name) 'preserve)
          argument
          (consent-native-argument-value argument context)))

    (define (native-binding-result library-key name value)
      "Bridge native VALUE back for NAME in LIBRARY-KEY."
      (if (eq? (native-binding-result-policy library-key name) 'host)
          (native-callback-result value '())
          (native-result-value value)))

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
          (apply (native-callback-shim value native-call-context)
                 arguments)))

    (define (native-nested-argument value context seen)
      "Convert one value nested inside a container crossing into native code."
      "Callables nested in data follow the callback convention -- a custom"
      "reader resync strategy or a policy-confirmation-function inside an"
      "options alist -- so they become host callbacks native higher-order"
      "code can apply directly. Ordinary `(scheme base)' scalar data keep"
      "their language-level surface here too: canonical number records and"
      "the interpreter's eof record unwrap to host Scheme values instead of"
      "leaking reader/runtime representation details into native consumers."
      "Pairs and vectors are walked copy-on-write so untouched structure"
      "keeps its identity. SEEN guards against cyclic data, which is"
      "returned unchanged on revisit."
      (cond
       ((consent-number? value)
        (let ((host (consent-number-value value)))
          (if (number? host) host value)))
       ((consent-eof-object? value)
        (eof-object))
       ((or (consent-procedure? value)
            (consent-primitive-procedure? value)
            (continuation? value)
            (consent-parameter? value))
        (native-callback-shim value context))
       ((pair? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (head (native-nested-argument (car value) context next-seen))
                   (tail (native-nested-argument (cdr value) context next-seen)))
              (if (and (eq? head (car value)) (eq? tail (cdr value)))
                  value
                  (cons head tail)))))
       ((vector? value)
        (if (memq value seen)
            value
            (let* ((next-seen (cons value seen))
                   (length (vector-length value))
                   (converted
                    (let loop ((index 0) (acc '()) (changed #f))
                      (if (= index length)
                          (and changed (reverse acc))
                          (let* ((element (vector-ref value index))
                                 (next (native-nested-argument
                                        element context next-seen)))
                            (loop (+ index 1)
                                  (cons next acc)
                                  (or changed (not (eq? next element)))))))))
              (if converted (list->vector converted) value))))
       (else value)))

    (define (consent-native-argument-value value context)
      "Convert one argument crossing into native code."
      "A bare callable argument crosses unchanged: it is the runtime's own"
      "procedure record, which native predicates, accessors, and the shared"
      "apply machinery already handle (consent-procedure? on a"
      "consent-eval-source result must see the record, not a wrapper)."
      "Numbers and eof objects cross as plain host Scheme values, and"
      "containers are walked so nested scalars and the options-alist"
      "callback convention both preserve the portable library surface."
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
          ("VALUE converted to the host-facing argument form: host numbers"
           "or eof objects for scalar runtime records, host callbacks for"
           "nested callables, and copy-on-write container rewrites when"
           "needed.")))
        (effects pure allocation))
      (if (or (pair? value)
              (vector? value)
              (consent-number? value)
              (consent-eof-object? value))
          (native-nested-argument value context '())
          value))

    (define (native-result-value value)
      "Convert one native RESULT for interpreted use."
      "Native unwrap accessors return raw host numbers (consent-number-value,"
      "read positions); interpreted callers expect canonical records,"
      "mirroring how char->integer wraps at the primitive boundary. A raw"
      "host procedure result (a REPL chrome lookup, for example) wraps as a"
      "native primitive through the shared binding cells so repeated lookups"
      "stay eqv? and the interpreted world can both recognize and apply it."
      "Every other host-owned datum crosses under the shared host-datum"
      "bridge, which canonicalizes numbers/eof and preserves source metadata"
      "on rebuilt structure."
      (consent-host-datum->consent-datum
       value
       (lambda (procedure)
         (cell-value
          (native-binding-cell '(native result) 'result procedure)))))

    (define (native-binding-value library-key name value)
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
           (string->symbol (string-append "native:" (symbol->string name)))
           (lambda (arguments context)
             (let ((previous native-call-context))
               (dynamic-wind
                (lambda () (set! native-call-context context))
                (lambda ()
                  (native-binding-result
                   library-key
                   name
                   (apply value
                          (map (lambda (argument)
                                 (native-binding-argument
                                  library-key
                                  name
                                  argument
                                  context))
                               arguments))
                  ))
                (lambda () (set! native-call-context previous)))))
           0
           #f)
          ;; Exported data values (for example consent-version-datum) may carry
          ;; raw host numbers a native reader would consume directly; convert
          ;; them once at registration so interpreted callers see canonical
          ;; numbers.
          (native-binding-result library-key name value)))

    ;; Cache pairing each registered native value and boundary policy with its
    ;; shared binding cell.
    (define native-binding-cells '())

    (define (native-binding-cell library-key name value)
      "Return the shared binding cell for native VALUE, creating it on first"
      "use. Internal libraries re-export one another's bindings ((consent"
      "eval) re-exports the (consent runtime) predicates, for example), and"
      "importing two such libraries into one program is only compatible when"
      "both export records carry the same boundary policy, so the cache key is"
      "the native VALUE plus its argument/result policy pair."
      (let* ((argument-policy (native-binding-argument-policy library-key name))
             (result-policy (native-binding-result-policy library-key name))
             (entry
              (let loop ((rest native-binding-cells))
                (if (null? rest)
                    #f
                    (let ((cell (car rest)))
                      (if (and (eq? (car cell) value)
                               (eq? (cadr cell) argument-policy)
                               (eq? (car (cdr (cdr cell))) result-policy))
                          cell
                          (loop (cdr rest))))))))
        (if entry
            (car (cdr (cdr (cdr entry))))
            (let ((cell (make-cell
                         (native-binding-value library-key name value))))
              (set! native-binding-cells
                    (cons (list value argument-policy result-policy cell)
                          native-binding-cells))
              cell))))

    (define (register-native-library! key bindings context)
      "Register internal library KEY from its compiled-in native BINDINGS table."
      (let ((value-environment (consent-make-empty-environment))
            (syntax-environment (library-make-empty-syntax-environment #f)))
        (for-each
         (lambda (binding)
           (set-environment-frame!
            value-environment
            (cons (cons (car binding)
                        (native-binding-cell key
                                             (car binding)
                                             (cdr binding)))
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
       ((eq? name (library-binding-name (car exports))) (car exports))
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
         ((memq (library-binding-name (car rest)) export-names)
          (loop (cdr rest) (cons (car rest) result)))
         (else (loop (cdr rest) result)))))

    (define (register-library-alias! spec context environment)
      "Register alias SPEC using its target library and optional exports."
      (let ((key (library-alias-field spec 'alias))
            (target-key (library-alias-field spec 'target))
            (export-names-entry (assq 'exports spec)))
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

    (define (manifest-library-alias-spec entry)
      "Return alias registration metadata for manifest ENTRY."
      (let ((key (collection-entry-field entry 'name #f))
            (target (collection-entry-field entry 'target #f))
            (exports (collection-entry-field entry 'exports '())))
        (if (not target)
            (eval-error "manifest alias has no target" key))
        (append
         (list (cons 'alias key)
               (cons 'target target))
         (if (null? exports)
             '()
             (list (cons 'exports exports))))))

    (define (library-alias-spec key aliases)
      "Return KEY's alias spec from ALIASES, or #f when KEY is not an alias."
      (cond
       ((null? aliases) #f)
       ((equal? key (library-alias-field (car aliases) 'alias))
        (car aliases))
       (else (library-alias-spec key (cdr aliases)))))

    (define (register-primitive-library! key primitive-specs context)
      "Register KEY as a library populated from primitive specs."
      (if (not (library-registry-ref context key))
          (let ((value-environment (consent-make-empty-environment))
                (syntax-environment (library-make-empty-syntax-environment #f)))
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
           ((eq? (library-binding-name (car rest)) name)
            (loop (cdr rest) #t (cons binding result)))
           (else
            (loop (cdr rest) replaced? (cons (car rest) result)))))))

    (define (register-library-primitive-bindings! key primitive-specs context)
      "Overlay PRIMITIVE-SPECS onto the already registered source library KEY."
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

    (define (memory-library-primitive-specs)
      "Return host adapter primitive specs layered over `(agent memory)'."
      (list
       (library-primitive-spec 'memory-put! 'primitive-memory-put! 3 3)
       (library-primitive-spec 'memory-ref 'primitive-memory-ref 2 2)
       (library-primitive-spec 'memory-delete! 'primitive-memory-delete! 2 2)
       (library-primitive-spec 'memory-add! 'primitive-memory-add! 3 3)
       (library-primitive-spec 'memory-find 'primitive-memory-find 2 2)
       (library-primitive-spec 'memory-by-tag 'primitive-memory-by-tag 2 2)
       (library-primitive-spec 'memory-recent 'primitive-memory-recent 2 2)
       (library-primitive-spec 'memory-access! 'primitive-memory-access! 3 3)
       (library-primitive-spec 'memory-reflect! 'primitive-memory-reflect! 6 6)
       (library-primitive-spec 'memory-select 'primitive-memory-select 4 4)
       (library-primitive-spec 'memory-yield 'primitive-memory-yield 2 2)))

    (define (session-library-primitive-specs)
      "Return primitive specs for the manifest `agent-session` implementation."
      (list
       (library-primitive-spec 'create-session
                               'primitive-create-session
                               0
                               2)
       (library-primitive-spec 'switch-session
                               'primitive-switch-session
                               1
                               1)
       (library-primitive-spec 'set-default-session!
                               'primitive-switch-session
                               1
                               1)
       (library-primitive-spec 'current-session
                               'primitive-current-session
                               0
                               0)
       (library-primitive-spec 'list-sessions
                               'primitive-list-sessions
                               0
                               1)
       (library-primitive-spec 'close-session
                               'primitive-close-session
                               1
                               1)))

    (define (char-library-specs)
      "Return primitive specs for `(scheme char)'."
      (list
       (library-primitive-spec 'char-alphabetic? 'primitive-char-alphabetic? 1 1)
       (library-primitive-spec 'char-ci<=? 'primitive-char-ci<=? 2 #f)
       (library-primitive-spec 'char-ci<? 'primitive-char-ci<? 2 #f)
       (library-primitive-spec 'char-ci=? 'primitive-char-ci=? 2 #f)
       (library-primitive-spec 'char-ci>=? 'primitive-char-ci>=? 2 #f)
       (library-primitive-spec 'char-ci>? 'primitive-char-ci>? 2 #f)
       (library-primitive-spec 'char-downcase 'primitive-char-downcase 1 1)
       (library-primitive-spec 'char-foldcase 'primitive-char-foldcase 1 1)
       (library-primitive-spec 'char-lower-case? 'primitive-char-lower-case? 1 1)
       (library-primitive-spec 'char-numeric? 'primitive-char-numeric? 1 1)
       (library-primitive-spec 'char-upcase 'primitive-char-upcase 1 1)
       (library-primitive-spec 'char-upper-case? 'primitive-char-upper-case? 1 1)
       (library-primitive-spec 'char-whitespace? 'primitive-char-whitespace? 1 1)
       (library-primitive-spec 'digit-value 'primitive-digit-value 1 1)
       (library-primitive-spec 'string-ci<=? 'primitive-string-ci<=? 2 #f)
       (library-primitive-spec 'string-ci<? 'primitive-string-ci<? 2 #f)
       (library-primitive-spec 'string-ci=? 'primitive-string-ci=? 2 #f)
       (library-primitive-spec 'string-ci>=? 'primitive-string-ci>=? 2 #f)
       (library-primitive-spec 'string-ci>? 'primitive-string-ci>? 2 #f)
       (library-primitive-spec 'string-downcase 'primitive-string-downcase 1 1)
       (library-primitive-spec 'string-foldcase 'primitive-string-foldcase 1 1)
       (library-primitive-spec 'string-upcase 'primitive-string-upcase 1 1)))

    (define (primitive-cxr-function name)
      "Implement the `cxr-function` primitive with argument validation and"
      "Consent Scheme values."
      (let ((text (symbol->string name)))
        (lambda (arguments context)
          (let loop ((index (- (string-length text) 2))
                     (value (car arguments)))
            (if (= index 0)
                value
                (let ((step (string-ref text index)))
                  (loop (- index 1)
                        (cond
                         ((char=? step #\a)
                          ((library-primitive-implementation 'primitive-car)
                           (list value) context))
                         ((char=? step #\d)
                          ((library-primitive-implementation 'primitive-cdr)
                           (list value) context))
                         (else
                          (eval-error "invalid cxr name" name))))))))))

    (define (cxr-library-specs entry)
      "Return primitive specs for manifest CXR library ENTRY."
      (map (lambda (name)
             (list name (primitive-cxr-function name) 1 1))
           (collection-entry-field entry 'exports '())))

    (define (inexact-library-specs)
      "Return primitive specs for `(scheme inexact)'."
      (list
       (library-primitive-spec 'acos 'primitive-acos 1 1)
       (library-primitive-spec 'asin 'primitive-asin 1 1)
       (library-primitive-spec 'atan 'primitive-atan 1 2)
       (library-primitive-spec 'cos 'primitive-cos 1 1)
       (library-primitive-spec 'exp 'primitive-exp 1 1)
       (library-primitive-spec 'finite? 'primitive-finite? 1 1)
       (library-primitive-spec 'infinite? 'primitive-infinite? 1 1)
       (library-primitive-spec 'log 'primitive-log 1 2)
       (library-primitive-spec 'nan? 'primitive-nan? 1 1)
       (library-primitive-spec 'sin 'primitive-sin 1 1)
       (library-primitive-spec 'sqrt 'primitive-sqrt 1 1)
       (library-primitive-spec 'tan 'primitive-tan 1 1)))

    (define (policy-denied-spec name)
      "Return a primitive spec that always raises a policy-denied error."
      (list name (library-policy-denied-primitive (symbol->string name)) 0 #f))

    (define (primitive-library-required-field entry field description)
      "Return FIELD from ENTRY or raise DESCRIPTION."
      (let ((cell (assq field entry)))
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
        (if (not (symbol? name))
            (eval-error "primitive export name must be a symbol" name))
        (if (not (symbol? primitive))
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
           (if (not (symbol? effect))
               (eval-error "primitive export effects must be symbols"
                           name)))
         (collection-entry-field export 'effects '()))
        (for-each
         (lambda (capability)
           (if (not (symbol? capability))
               (eval-error
                "primitive export capabilities must be symbols"
                name)))
         (collection-entry-field export 'capabilities '()))
        #t))

    (define (validate-primitive-library-declaration declaration)
      "Validate and return primitive-library DECLARATION."
      (if (not (eq? (collection-entry-field declaration 'kind #f)
                    'primitive-library))
          (eval-error
           "primitive-library declaration must have kind primitive-library"
           (collection-entry-field declaration 'name #f)))
      (if (not (eq? (collection-entry-field declaration 'source-kind #f)
                    'primitive))
          (eval-error
           "primitive-library declaration must have source-kind primitive-library"
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
                      (symbol? owner)
                      (symbol? provider)
                      (symbol? visibility)
                      (symbol? layer)
                      (symbol? implementation-id)))
            (eval-error
             "primitive-library declaration has invalid identity metadata"
             name))
        (if (or (null? exports)
                (not (let loop ((rest exports))
                       (cond
                        ((null? rest) #t)
                        ((symbol? (car rest)) (loop (cdr rest)))
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
                  (if (memq export-name names)
                      (eval-error
                       "duplicate primitive export in declaration"
                       export-name))
                  (loop (cdr rest) (cons export-name names))))
              (begin
                (for-each
                 (lambda (export)
                   (if (not (memq export names))
                       (eval-error
                        "primitive-library export lacks primitive metadata"
                        export)))
                 exports)
                (for-each
                 (lambda (export)
                   (if (not (memq export exports))
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
      "Register `(scheme r5rs)' with R5RS aliases for exact/inexact conversion."
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
          (let ((implementation-id
                 (collection-entry-field entry 'implementation-id #f)))
            (cond
         ((eq? implementation-id 'scheme-char) (char-library-specs))
         ((eq? implementation-id 'scheme-complex)
          (list
           (library-primitive-spec 'angle 'primitive-angle 1 1)
           (library-primitive-spec 'imag-part 'primitive-imag-part 1 1)
           (library-primitive-spec 'magnitude 'primitive-magnitude 1 1)
           (library-primitive-spec 'make-polar 'primitive-make-polar 2 2)
           (library-primitive-spec 'make-rectangular
                                   'primitive-make-rectangular
                                   2
                                   2)
           (library-primitive-spec 'real-part 'primitive-real-part 1 1)))
         ((eq? implementation-id 'scheme-cxr) (cxr-library-specs entry))
         ((eq? implementation-id 'scheme-eval)
          (list
           (library-primitive-spec 'environment 'primitive-environment 1 #f)
           (library-primitive-spec 'eval 'primitive-eval 2 2)))
         ((eq? implementation-id 'scheme-file)
          (list
           (library-primitive-spec 'call-with-input-file
                                   'primitive-call-with-input-file
                                   2
                                   2)
           (library-primitive-spec 'call-with-output-file
                                   'primitive-call-with-output-file
                                   2
                                   2)
           (library-primitive-spec 'delete-file 'primitive-delete-file 1 1)
           (library-primitive-spec 'file-exists? 'primitive-file-exists? 1 1)
           (library-primitive-spec 'open-binary-input-file
                                   'primitive-open-binary-input-file
                                   1
                                   1)
           (library-primitive-spec 'open-binary-output-file
                                   'primitive-open-binary-output-file
                                   1
                                   1)
           (library-primitive-spec 'open-input-file
                                   'primitive-open-input-file
                                   1
                                   1)
           (library-primitive-spec 'open-output-file
                                   'primitive-open-output-file
                                   1
                                   1)
           (library-primitive-spec 'with-input-from-file
                                   'primitive-with-input-from-file
                                   2
                                   2)
           (library-primitive-spec 'with-output-to-file
                                   'primitive-with-output-to-file
                                   2
                                   2)))
         ((eq? implementation-id 'scheme-inexact) (inexact-library-specs))
         ((eq? implementation-id 'scheme-load)
          (list (library-primitive-spec 'load 'primitive-load 1 2)))
         ((eq? implementation-id 'scheme-process-context)
          (append
           (list
            (library-primitive-spec 'command-line
                                    'primitive-command-line
                                    0
                                    0))
           (map policy-denied-spec '(emergency-exit exit))
           (list
            (library-primitive-spec 'get-environment-variable
                                    'primitive-get-environment-variable
                                    1
                                    1)
            (library-primitive-spec 'get-environment-variables
                                    'primitive-get-environment-variables
                                    0
                                    0))))
         ((eq? implementation-id 'scheme-read)
          (list (library-primitive-spec 'read 'primitive-read 0 1)))
         ((eq? implementation-id 'scheme-repl)
          (list
           (library-primitive-spec 'interaction-environment
                                   'primitive-interaction-environment
                                   0
                                   0)))
         ((eq? implementation-id 'scheme-time)
          (list
           (library-primitive-spec 'current-jiffy
                                   'primitive-current-jiffy
                                   0
                                   0)
           (library-primitive-spec 'current-second
                                   'primitive-current-second
                                   0
                                   0)
           (library-primitive-spec 'jiffies-per-second
                                   'primitive-jiffies-per-second
                                   0
                                   0)))
         ((eq? implementation-id 'scheme-write)
          (list
           (library-primitive-spec 'display 'primitive-display 1 2)
           (library-primitive-spec 'write 'primitive-write 1 2)
           (library-primitive-spec 'write-shared 'primitive-write-shared 1 2)
           (library-primitive-spec 'write-simple 'primitive-write-simple 1 2)))
         ((eq? implementation-id 'agent-io)
          (list
           (library-primitive-spec 'agent-yield 'primitive-agent-yield 1 1)
           (library-primitive-spec 'agent-log 'primitive-agent-log 2 #f)
           (library-primitive-spec 'agent-progress
                                   'primitive-agent-progress
                                   2
                                   2)
           (library-primitive-spec 'agent-warn 'primitive-agent-warn 1 #f)
           (library-primitive-spec 'agent-request
                                   'primitive-agent-request
                                   1
                                   1)))
         ((eq? implementation-id 'agent-approval)
          (list
           (library-primitive-spec 'approval-request!
                                   'primitive-approval-request!
                                   1
                                   1)
           (library-primitive-spec 'approval-status
                                   'primitive-approval-status
                                   1
                                   1)
           (library-primitive-spec 'approval-cancel!
                                   'primitive-approval-cancel!
                                   1
                                   1)
           (library-primitive-spec 'approval-yield-pending
                                   'primitive-approval-yield-pending
                                   0
                                   0)
           (library-primitive-spec 'approval-resolve!
                                   'primitive-approval-resolve!
                                   2
                                   2)))
         ((eq? implementation-id 'agent-debugger)
          (list
           (library-primitive-spec 'current-error 'primitive-current-error 0 0)
           (library-primitive-spec 'condition-stack
                                   'primitive-condition-stack
                                   1
                                   1)
           (library-primitive-spec 'condition-environment
                                   'primitive-condition-environment
                                   2
                                   2)
           (library-primitive-spec 'condition-restarts
                                   'primitive-condition-restarts
                                   1
                                   1)
           (library-primitive-spec 'restart-invoke!
                                   'primitive-restart-invoke!
                                   2
                                   2)
           (library-primitive-spec 'debugger-yield
                                   'primitive-debugger-yield
                                   1
                                   1)))
         ((eq? implementation-id 'agent-helper)
          (list
           (library-primitive-spec 'agent-artifact
                                   'primitive-agent-artifact
                                   2
                                   2)
           (library-primitive-spec 'agent-helper-save!
                                   'primitive-agent-helper-save!
                                   2
                                   3)
           (library-primitive-spec 'agent-helper-load
                                   'primitive-agent-helper-load
                                   1
                                   2)
           (library-primitive-spec 'agent-helper-list
                                   'primitive-agent-helper-list
                                   1
                                   1)
           (library-primitive-spec 'agent-helper-ref
                                   'primitive-agent-helper-ref
                                   1
                                   2)
           (library-primitive-spec 'agent-helper-promote-to-skill
                                   'primitive-agent-helper-promote-to-skill
                                   1
                                   2)))
         ((eq? implementation-id 'agent-job)
          (list
           (library-primitive-spec 'job-start! 'primitive-job-start! 3 3)
           (library-primitive-spec 'job-ref 'primitive-job-ref 1 1)
           (library-primitive-spec 'job-list 'primitive-job-list 0 1)
           (library-primitive-spec 'job-cancel! 'primitive-job-cancel! 1 1)
           (library-primitive-spec 'job-interrupt!
                                   'primitive-job-interrupt!
                                   2
                                   2)
           (library-primitive-spec 'job-yields 'primitive-job-yields 1 2)
           (library-primitive-spec 'job-status 'primitive-job-status 1 1)))
         ((eq? implementation-id 'agent-test)
          (list
           (library-primitive-spec 'agent-test-eval-source-result
                                   'primitive-agent-test-eval-source-result
                                   1
                                   2)))
         ((eq? implementation-id 'agent-memory)
          (memory-library-primitive-specs))
         ((eq? implementation-id 'agent-plan)
          (list
           (library-primitive-spec 'plan-create!
                                   'primitive-plan-create!
                                   1
                                   1)
           (library-primitive-spec 'plan-ref 'primitive-plan-ref 1 1)
           (library-primitive-spec 'plan-list 'primitive-plan-list 1 1)
           (library-primitive-spec 'plan-step-add!
                                   'primitive-plan-step-add!
                                   2
                                   2)
           (library-primitive-spec 'plan-step-status!
                                   'primitive-plan-step-status!
                                   3
                                   3)
           (library-primitive-spec 'plan-status!
                                   'primitive-plan-status!
                                   2
                                   2)
           (library-primitive-spec 'plan-yield 'primitive-plan-yield 1 1)))
         ((eq? implementation-id 'agent-models)
          (list
           (library-primitive-spec 'primitive-model-provider-register!
                                   'primitive-model-provider-register!
                                   1
                                   1)
           (library-primitive-spec 'primitive-model-providers
                                   'primitive-model-providers
                                   0
                                   0)
           (library-primitive-spec 'primitive-model-route
                                   'primitive-model-route
                                   1
                                   2)
           (library-primitive-spec 'primitive-model-complete
                                   'primitive-model-complete
                                   2
                                   3)
           (library-primitive-spec 'primitive-model-provider-diagnostics
                                   'primitive-model-provider-diagnostics
                                   0
                                   1)))
         ((eq? implementation-id 'agent-context)
          (list
           (library-primitive-spec 'current-request
                                   'primitive-current-request
                                   0
                                   0)
           (library-primitive-spec 'current-focus
                                   'primitive-current-focus
                                   0
                                   0)
           (library-primitive-spec 'current-region-context
                                   'primitive-current-region-context
                                   0
                                   0)
           (library-primitive-spec 'current-buffer-context
                                   'primitive-current-buffer-context
                                   0
                                   0)
           (library-primitive-spec 'current-project-context
                                   'primitive-current-project-context
                                   0
                                   0)
           (library-primitive-spec 'current-conversation-summary
                                   'primitive-current-conversation-summary
                                   0
                                   0)
           (library-primitive-spec 'context-yield
                                   'primitive-context-yield
                                   1
                                   1)))
         ((eq? implementation-id 'agent-redaction)
          (list
           (library-primitive-spec 'secret-source?
                                   'primitive-secret-source?
                                   1
                                   1)
           (library-primitive-spec 'redact 'primitive-redact 2 2)
           (library-primitive-spec 'context-local-only!
                                   'primitive-context-local-only!
                                   2
                                   2)
           (library-primitive-spec 'redaction-log
                                   'primitive-redaction-log
                                   0
                                   1)
           (library-primitive-spec 'safe-for-provider?
                                   'primitive-safe-for-provider?
                                   2
                                   2)))
         ((eq? implementation-id 'agent-session)
          (session-library-primitive-specs))
         ((eq? implementation-id 'consent-capability)
          (list
           (library-primitive-spec 'grant-capability!
                                   'primitive-grant-capability!
                                   1
                                   1)
           (library-primitive-spec 'current-grants
                                   'primitive-current-grants
                                   0
                                   0)
           (library-primitive-spec 'grant-ref 'primitive-grant-ref 1 1)
           (library-primitive-spec 'grant-attenuate
                                   'primitive-grant-attenuate
                                   2
                                   2)
           (library-primitive-spec 'grant-revoke!
                                   'primitive-grant-revoke!
                                   1
                                   1)
           (library-primitive-spec 'call-with-capability-grant
                                   'primitive-call-with-capability-grant
                                   2
                                   2)
           (library-primitive-spec 'handle-ref 'primitive-handle-ref 1 1)
           (library-primitive-spec 'handle-live? 'primitive-handle-live? 1 1)
           (library-primitive-spec 'handle-kind 'primitive-handle-kind 1 1)
           (library-primitive-spec 'handle-revalidate
                                   'primitive-handle-revalidate
                                   1
                                   1)
           (library-primitive-spec 'handle-release!
                                   'primitive-handle-release!
                                   1
                                   1)))
         (else
          #f)))))

    (define (manifest-implementation-available? entry)
      "Report whether manifest ENTRY has an implementation on this host."
      (let ((kind (collection-entry-field entry 'source-kind #f)))
        (cond
         ((consent-native-library-ref
           (collection-entry-field entry 'name #f))
          #t)
         ((eq? kind 'primitive)
          (if (primitive-library-declaration? entry)
              (and (validate-primitive-library-declaration entry) #t)
              (and (manifest-primitive-implementation-specs entry) #t)))
         ((eq? kind 'derived)
          (eq? (collection-entry-field entry 'implementation-id #f)
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
               ((memq (car (car rest)) exports)
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
             "manifest primitive library has no implementation id"
             (collection-entry-field entry 'name #f)))))

    (define (manifest-library-routable? entry)
      "Report whether manifest ENTRY describes an import route."
      (and entry
           (let ((kind (collection-entry-field entry 'source-kind #f)))
             (or (collection-entry-field entry 'target #f)
                 (collection-entry-field entry 'source-file #f)
                 (eq? kind 'base-snapshot)
                 (and (memq kind '(primitive derived))
                      (manifest-implementation-available? entry))))))

    (define (register-manifest-source-library! entry context environment)
      "Register source library described by manifest ENTRY."
      (let ((key (collection-entry-field entry 'name #f))
            (source-file (collection-entry-field entry 'source-file #f))
            (root (collection-entry-field entry 'root #f))
            (exports (collection-entry-field entry 'exports '()))
            (overlay-library
             (collection-entry-field entry 'primitive-overlay-library #f)))
        (if (not source-file)
            (eval-error "manifest source library has no source-file" key))
        (if (not (library-registry-ref context key))
            (register-source-library!
             (manifest-source-library-source source-file key root)
             context
             environment))
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
        (if (not (null? exports))
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

    (define (register-manifest-implementation-library! entry context environment)
      "Register primitive or derived library described by manifest ENTRY."
      (let ((key (collection-entry-field entry 'name #f))
            (native-bindings
             (consent-native-library-ref
              (collection-entry-field entry 'name #f))))
        (cond
         (native-bindings
          (register-native-library! key native-bindings context))
         ((eq? (collection-entry-field entry 'source-kind #f)
               'primitive)
          (register-primitive-library!
           key
           (manifest-exported-primitive-specs entry)
           context))
         ((and (eq? (collection-entry-field entry 'source-kind #f)
                    'derived)
               (eq? (collection-entry-field entry 'implementation-id #f)
                    'scheme-r5rs))
          (register-r5rs-library! key context environment))
         (else
          (eval-error
           "manifest primitive library has no implementation id"
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
          (description ("Environment available for resolving the library name."))))
        (returns (type boolean)
         (description
          ("#t when NAME names a known, registered, or host-loadable"
            "library, else #f.")))
        (effects state-read error))
      (let* ((key (library-name-key name))
             (entry (library-collection-manifest-entry key)))
        (and
         (or (not (library-visibility-internal?
                   (library-visibility key)))
             (library-internal-import-allowed? context))
         (or (not entry)
             (library-entry-available? entry))
         (or (manifest-library-routable? entry)
             (and (library-registry-ref context key) #t)))))

    (define (resolve-library name context environment)
      "Resolve NAME to a library, registering lazy standard libraries as needed."
      #((parameters
         (name (type (list-of (or symbol exact-integer)))
          (description "Library name to resolve to a registered library."))
         (context (type eval-context)
          (description
           ("Evaluation context whose registry receives lazily"
             "registered libraries.")))
         (environment (type environment)
          (description ("Environment used when building or registering the library."))))
        (returns (type library)
         (description "The resolved library object for NAME."))
        (effects state-read state-write error))
      (let* ((key (library-name-key name))
             (entry (library-collection-manifest-entry key)))
        (ensure-library-import-allowed key context)
        (if (and entry (not (library-entry-available? entry)))
            (eval-error "optional library is unavailable on this host" key))
        (if (not (library-registry-ref context key))
            (cond
             ((not entry) #f)
             ((collection-entry-field entry 'target #f)
              (register-library-alias!
               (manifest-library-alias-spec entry)
               context
               environment))
             ((eq? (collection-entry-field entry 'source-kind #f)
                   'base-snapshot)
              (register-scheme-base-library! context environment))
             ((collection-entry-field entry 'source-file #f)
              (register-manifest-source-library! entry context environment))
             ((memq (collection-entry-field entry 'source-kind #f)
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
       ((eq? name (library-binding-name (car bindings))) (car bindings))
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
          (description ("List of import library bindings to deduplicate and check."))))
        (returns (type list)
         (description ("A list of bindings with compatible duplicates merged.")))
        (effects error))
      (let loop ((rest bindings) (seen '()) (result '()))
        (if (null? rest)
            (reverse result)
            (let* ((binding (car rest))
                   (name (library-binding-name binding))
                   (previous (assq name seen)))
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
                 ((memq (library-binding-name (car rest)) names)
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
                 ((memq (library-binding-name (car rest)) names)
                  (loop (cdr rest) result))
                 (else (loop (cdr rest) (cons (car rest) result)))))))
           ((identifier-named? operator 'prefix)
            (if (not (= (length parts) 3))
                (eval-error
                 "prefix import set requires an import set and prefix"))
            (let ((prefix
                   (symbol->string
                    (expect-symbol (third parts) "prefix identifier"))))
              (map
               (lambda (binding)
                 (library-binding-with-name
                  binding
                  (string->symbol
                   (string-append
                    prefix
                    (symbol->string (library-binding-name binding))))))
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
                        (assq (library-binding-name binding) renames)))
                   (if rename
                       (library-binding-with-name binding (cdr rename))
                       binding)))
               bindings)))
           (else
            (eval-error "invalid import set" import-set)))))
       (else
        (eval-error "invalid import set" import-set))))

    (define (install-imported-binding! binding value-environment
                                       syntax-environment)
      "Install one imported value or syntax binding into the target frames."
      (let ((name (library-binding-name binding))
            (kind (library-binding-kind binding))
            (object (library-binding-object binding))
            (binding-library-key (library-binding-library-key binding)))
        (cond
         ((eq? kind 'value)
          (let ((existing (frame-cell value-environment name)))
            (cond
             ((not existing)
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((equal? binding-library-key scheme-base-library-key)
              ;; Repeated `(scheme base)' imports are common while source
              ;; libraries bootstrap; reinstalling the same base name is
              ;; harmless and keeps import-set handling small.
              (set-environment-frame!
               value-environment
               (cons (cons name object)
                     (environment-frame value-environment))))
             ((eq? existing object))
             (else
              (eval-error "conflicting import for identifier" name))))
          (if (not (memq name (environment-imported-names value-environment)))
              (set-environment-imported-names!
               value-environment
               (cons name (environment-imported-names value-environment)))))
         ((eq? kind 'syntax)
          (let ((existing (current-syntax-binding syntax-environment name)))
            (cond
             ((or (not existing)
                  (equal? binding-library-key scheme-base-library-key))
              (set-syntax-environment-frame!
               syntax-environment
               (cons (cons name object)
                     (syntax-environment-frame syntax-environment))))
             ((eq? existing object))
             (else
              (eval-error "conflicting syntax import for identifier" name))))
          (if (not (memq name
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
                                    syntax-environment))
       (ensure-compatible-import-bindings
        (resolve-import-set import-set context value-environment))))

    (define (eval-import form environment context)
      "Evaluate an import declaration into the active value and syntax frames."
      #((parameters
         (form (type pair)
          (description ("Import declaration form whose import sets are installed.")))
         (environment (type environment)
          (description ("Value environment receiving the imported value bindings.")))
         (context (type eval-context)
          (description
           ("Evaluation context whose syntax environment and registry"
             "are used."))))
        (returns . ("The unspecified value after installing every import set."))
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
          (description ("List of export clause forms (identifiers or rename forms)."))))
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
                       "export rename requires internal and external identifiers"))
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
        (memq (identifier-datum-name requirement) '(r7rs consent)))
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
      "Select declarations from the first satisfied library cond-expand clause."
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
      "Resolve FILENAME against the include directory and enforce file policy."
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
         (description ("A string holding the entire contents of the file at PATH.")))
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
      "Read and parse all forms from an include file, returning forms and directory."
      (let* ((path (resolve-include-file
                    filename
                    context
                    operation
                    (if (eq? operation 'include-ci)
                        "include-ci"
                        (if (eq? operation 'library-source)
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
              (library-syntax-environment-ref syntax-environment internal-name)))
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
                (syntax-environment (library-make-empty-syntax-environment #f)))
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
                             "include-library-declarations must expand before evaluation"
                             operator))
                           (else
                            (eval-error
                             "unsupported library declaration"
                             declaration))))))))))))

    ))
