;;; consent-library.el --- R7RS library resolver support  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Library records, source-library discovery, import-set resolution, and
;; define-library bootstrap support.  This module is loadable without the
;; evaluator backend; functions that evaluate library bodies use backend hooks
;; supplied by `consent-eval' after it loads.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'consent-reader)
(require 'consent-runtime)
(require 'consent-result)
(require 'consent-base)
(require 'consent-capability)
(require 'consent-agent-io)
(require 'consent-approval)
(require 'consent-context)
(require 'consent-debugger)
(require 'consent-helper)
(require 'consent-job)
(require 'consent-memory)
(require 'consent-models)
(require 'consent-plan)
(require 'consent-redaction)
(require 'consent-reflect)
(require 'consent-session)
(require 'consent-test)
(require 'consent-transcript)
(require 'consent-policy)

(defconst consent--library-module-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Consent Scheme library module.")

(defcustom consent-library-seed-directory
  (expand-file-name "../scheme/" consent--library-module-directory)
  "Root directory containing seeded Scheme library manifests and sources."
  :type 'directory
  :group 'consent)

(defvar consent--source-library-environments (make-hash-table :test #'equal)
  "Private evaluator environments used for source-backed adapter calls.")

(defvar consent--source-library-procedures (make-hash-table :test #'equal)
  "Cached source-backed procedures keyed by library and procedure name.")

(defvar consent--source-library-internal-imports-allowed nil
  "Non-nil while loading trusted runtime source libraries.")

(defconst consent--source-library-call-options
  '(:max-steps 12000000
    :max-host-callbacks 2000000)
  "Evaluation budget for calls into cached source-backed libraries.")

(defvar consent--library-catalog-cache nil
  "Cached manifest-backed library catalog entries.")

(defvar consent--library-collection-manifest-cache nil
  "Cached metadata read from repo-owned collection manifests.")

(defvar consent--library-catalog-ad-hoc-manifests nil
  "Ad-hoc manifest catalog sources, as (SOURCE-ID . ENTRIES).")

(defvar consent--library-catalog-root-manifests nil
  "Explicit manifest-root catalog sources, as (ROOT . ENTRIES).")

(defvar consent--library-catalog-diagnostics nil
  "Diagnostics from the most recent manifest-backed catalog build.")

(declare-function consent--apply-procedure "consent-interpreter")
(declare-function consent--make-empty-syntax-environment "consent-macro")
(declare-function consent--policy-denied "consent-interpreter")
(declare-function consent--syntax-environment-ref "consent-macro")
(declare-function consent--trampoline "consent-interpreter")
(declare-function consent--with-syntax-environment "consent-macro")

(cl-defstruct (consent--library-binding
               (:constructor consent--make-library-binding
                             (name kind object library-key))
               (:copier nil))
  "One exported or imported library binding."
  name kind object library-key)

(cl-defstruct (consent--library
               (:constructor consent--make-library
                             (name key exports value-environment
                                   syntax-environment))
               (:copier nil))
  "Loaded Scheme library with explicit environments and exports."
  name key exports value-environment syntax-environment)

(defconst consent--library-manifest-index-file
  "manifest/index.sld"
  "Seed-root-relative top-level Scheme manifest index source file.")

(defun consent--manifest-source-library-form (key source-file description)
  "Return the single define-library form for KEY from manifest SOURCE-FILE."
  (let ((forms
         (consent-read-all
          (consent--manifest-source-library-source source-file key))))
    (unless (= (length forms) 1)
      (consent--eval-error
       "%s must contain exactly one form: %s"
       description
       key))
    (let* ((form (car forms))
           (parts (consent--proper-list-elements
                   form description)))
      (unless (and (>= (length parts) 2)
                   (consent--symbol-named-p
                    (car parts) "define-library")
                   (equal (consent-datum->external
                           (consent--strip-identifiers (cadr parts)))
                          key))
        (consent--eval-error
         "%s name does not match registry key: %s" description key))
      form)))

(defun consent--source-library-export-names (form)
  "Return external export names declared by source library FORM."
  (let ((parts (consent--proper-list-elements
                form "source library"))
        exports)
    (dolist (declaration (cddr parts))
      (when (consent--form-named-p declaration "export")
        (setq exports
              (append exports
                      (mapcar
                       #'cdr
                       (consent--export-specs
                        (cdr (consent--proper-list-elements
                              declaration "source export"))))))))
    exports))

(defun consent-standard-source-library-specs ()
  "Return metadata for standard libraries loaded from portable source files."
  (mapcar
   (lambda (manifest-entry)
     (let* ((key (plist-get manifest-entry :name))
            (source-file (plist-get manifest-entry :source-file))
            (form (consent--manifest-source-library-form
                   key
                   source-file
                   "standard source library")))
       (list :name key
             :exports
             (consent--source-library-export-names form)
             :source-file
             (consent--manifest-source-library-file source-file))))
   (seq-filter
    (lambda (entry)
      (and (eq (plist-get entry :category) 'standard)
           (eq (plist-get entry :source-kind) 'portable-source)))
    (consent--library-collection-manifest-entries))))

(defun consent--library-catalog-source-file (key)
  "Return manifest-provided source path for library KEY, or nil."
  (plist-get (consent--library-collection-manifest-entry key)
             :source-file))

(defun consent--library-catalog-category (key)
  "Return the public catalog category for library KEY."
  (or (plist-get (consent--library-collection-manifest-entry key)
                 :category)
      'library))

(defun consent--library-manifest-source-file (relative-file)
  "Return absolute path for seed-root-relative manifest RELATIVE-FILE."
  (expand-file-name relative-file consent-library-seed-directory))

(defun consent--library-read-file (source-file description)
  "Return SOURCE-FILE contents, or signal DESCRIPTION."
  (unless (file-readable-p source-file)
    (consent--eval-error "%s is not readable: %s" description source-file))
  (with-temp-buffer
    (insert-file-contents source-file)
    (buffer-string)))

(defun consent--library-manifest-index-source ()
  "Return the top-level Scheme manifest index source."
  (consent--library-read-file
   (consent--library-manifest-source-file
    consent--library-manifest-index-file)
   "top-level manifest index file"))

(defun consent--collection-manifest-source (spec)
  "Return source text for collection manifest described by SPEC."
  (consent--library-read-file
   (consent--library-manifest-source-file
    (plist-get spec :manifest-file))
   "collection manifest source file"))

(defun consent--collection-manifest-quoted-value (value variable key)
  "Return quoted manifest VALUE for VARIABLE in manifest library KEY."
  (let ((parts (and (consp value)
                    (consent--proper-list-elements value "quoted manifest"))))
    (unless (and (= (length parts) 2)
                 (consent--symbol-named-p (car parts) "quote"))
      (consent--eval-error
       "collection manifest variable must be quoted: %s in %s"
       variable key))
    (cadr parts)))

(defun consent--collection-manifest-define-value (form variable key)
  "Return manifest data from DEFINE FORM for VARIABLE and KEY, or nil."
  (when (consent--form-named-p form "define")
    (let ((parts (consent--proper-list-elements
                  form "collection manifest define")))
      (when (and (= (length parts) 3)
                 (consent--symbol-named-p (cadr parts) variable))
        (consent--collection-manifest-quoted-value
         (nth 2 parts) variable key)))))

(defun consent--manifest-library-quoted-variable
    (source key variable description)
  "Return quoted VARIABLE from manifest library SOURCE."
  (let* ((forms (consent-read-all source)))
    (unless (= (length forms) 1)
      (consent--eval-error
       "%s must contain exactly one form: %s" description key))
    (let* ((form (car forms))
           (parts (consent--proper-list-elements
                   form description)))
      (unless (and (>= (length parts) 2)
                   (consent--symbol-named-p (car parts) "define-library")
                   (or (null key)
                       (equal (consent-datum->external
                               (consent--strip-identifiers (cadr parts)))
                              key)))
        (consent--eval-error
         "%s library name does not match registry key: %s"
         description key))
      (catch 'manifest
        (dolist (declaration (cddr parts))
          (cond
           ((consent--form-named-p declaration "begin")
            (dolist (body-form (cdr (consent--proper-list-elements
                                     declaration
                                     "collection manifest begin")))
              (let ((value
                     (consent--collection-manifest-define-value
                      body-form variable key)))
                (when value
                  (throw 'manifest value)))))
           (t
            (let ((value
                   (consent--collection-manifest-define-value
                    declaration variable key)))
              (when value
                (throw 'manifest value))))))
        (consent--eval-error
         "%s variable is not defined: %s in %s"
         description variable key)))))

(defun consent--library-manifest-index-value ()
  "Return the quoted top-level manifest index."
  (consent--manifest-library-quoted-variable
   (consent--library-manifest-index-source)
   "(manifest index)"
   "manifest-index"
   "top-level manifest index"))

(defun consent--collection-manifest-library-value (spec)
  "Return the quoted manifest data described by SPEC."
  (consent--manifest-library-quoted-variable
   (consent--collection-manifest-source spec)
   (plist-get spec :key)
   (plist-get spec :variable)
   "collection manifest library"))

(defun consent--collection-manifest-field (entry name &optional default)
  "Return NAME from alist ENTRY, or DEFAULT when absent."
  (let ((cell
         (seq-find
          (lambda (field)
            (and (consp field)
                 (consent--symbol-named-p (car field) name)))
          entry)))
    (if cell
        (cdr cell)
      default)))

(defun consent--collection-manifest-symbol (value description &optional default)
  "Return VALUE as an Emacs Lisp symbol, or DEFAULT when absent."
  (cond
   ((or (null value) (eq value consent-false)) default)
   ((symbolp value) value)
   ((consent-symbol-p value) (intern (consent-symbol-name value)))
   (t (consent--eval-error "%s must be a symbol" description))))

(defun consent--collection-manifest-string (value description)
  "Return VALUE as a string, or signal DESCRIPTION."
  (if (stringp value)
      value
    (consent--eval-error "%s must be a string" description)))

(defun consent--collection-manifest-index-entry (entry)
  "Return a collection manifest descriptor parsed from index ENTRY."
  (let* ((collection
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "collection" nil)
           "manifest index collection"))
         (key
          (consent--library-name-key
           (consent--collection-manifest-field entry "manifest-library" nil)))
         (variable
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "manifest-variable" nil)
           "manifest index variable"))
         (manifest-file
          (consent--collection-manifest-string
           (consent--collection-manifest-field entry "manifest-file" nil)
           "manifest index manifest-file"))
         (source-root
          (consent--collection-manifest-string
           (consent--collection-manifest-field entry "source-root" nil)
           "manifest index source-root"))
         (category
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "category" nil)
           "manifest index category"
           collection)))
    (list :collection collection
          :key key
          :variable (symbol-name variable)
          :manifest-file manifest-file
          :category category
          :source-root source-root
          :source-id collection)))

(defun consent--library-collection-manifest-specs ()
  "Return collection manifest descriptors from the top-level manifest index."
  (mapcar
   #'consent--collection-manifest-index-entry
   (consent--proper-list-elements
    (consent--library-manifest-index-value)
    "top-level manifest index entries")))

(defun consent--collection-manifest-catalog-source-file
    (spec source-kind source-file)
  "Return repository-relative SOURCE-FILE for SPEC, or nil."
  (when (and source-kind source-file)
    (concat (plist-get spec :source-root) source-file)))

(defun consent--collection-manifest-source-kind (value)
  "Return VALUE normalized to the catalog source-kind vocabulary."
  (pcase (consent--collection-manifest-symbol
          value "collection manifest source-kind" nil)
    ('nil nil)
    ('source-library 'portable-source)
    ('primitive-library 'primitive)
    (symbol symbol)))

(defun consent--collection-manifest-library-list (value description)
  "Return VALUE normalized as a list of library-name keys."
  (if (or (null value) (eq value consent-false))
      nil
    (mapcar
     #'consent--library-name-key
     (consent--proper-list-elements value description))))

(defun consent--collection-manifest-target (value)
  "Return VALUE normalized as a library-name key, or nil."
  (unless (or (null value) (eq value consent-false))
    (consent--library-name-key value)))

(defun consent--collection-manifest-export-list (value description)
  "Return VALUE as a list of exported symbol names."
  (if (or (null value) (eq value consent-false))
      nil
    (mapcar
     (lambda (entry)
       (consent--expect-symbol-name entry description))
     (consent--proper-list-elements value description))))

(defun consent--collection-manifest-default-visibility (status)
  "Return the default visibility implied by manifest STATUS."
  (if (eq status 'alias) 'alias 'public))

(defun consent--collection-manifest-entry (entry spec)
  "Return catalog metadata parsed from collection manifest ENTRY and SPEC."
  (let* ((key
          (consent--library-name-key
           (consent--collection-manifest-field entry "library" nil)))
         (status
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "status" nil)
           "collection manifest status"
           'implemented))
         (visibility
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "visibility" nil)
           "collection manifest visibility"
           (consent--collection-manifest-default-visibility status)))
         (layer
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "layer" nil)
           "collection manifest layer"
           nil))
         (availability
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "availability" nil)
           "collection manifest availability"
           'required))
         (category
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "category" nil)
           "collection manifest category"
           (plist-get spec :category)))
         (availability-condition
          (consent--collection-manifest-field
           entry "availability-condition" nil))
         (target
          (consent--collection-manifest-target
           (consent--collection-manifest-field entry "target" nil)))
         (source-kind
          (or (consent--collection-manifest-source-kind
               (consent--collection-manifest-field entry "source-kind" nil))
              (and target 'alias)))
         (implementation-id
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "implementation-id" nil)
           "collection manifest implementation-id"
           nil))
         (primitive-overlay-library
          (consent--collection-manifest-target
           (consent--collection-manifest-field
            entry "primitive-overlay-library" nil)))
         (exports-absent (list 'exports-absent))
         (source-file
          (consent--collection-manifest-field entry "source-file" nil))
         (dependencies
          (consent--collection-manifest-library-list
           (consent--collection-manifest-field entry "dependencies" nil)
           "collection manifest dependencies"))
         (aliases
          (consent--collection-manifest-library-list
           (consent--collection-manifest-field entry "aliases" nil)
           "collection manifest aliases"))
         (exports
          (let ((value (consent--collection-manifest-field
                        entry "exports" exports-absent)))
            (if (eq value exports-absent)
                exports-absent
              (consent--collection-manifest-export-list
               value
               "collection manifest exports"))))
         (summary
          (consent--collection-manifest-field entry "summary" nil)))
    (when (eq source-file consent-false)
      (setq source-file nil))
    (unless (or (null source-file) (stringp source-file))
      (consent--eval-error
       "collection manifest source-file must be a string or #f"))
    (setq source-file
          (consent--collection-manifest-catalog-source-file
           spec source-kind source-file))
    (when (eq exports exports-absent)
      (consent--eval-error
       "built-in manifest entry must declare exports: %s"
       key))
    (when (eq summary consent-false)
      (setq summary nil))
    (unless (or (null summary) (stringp summary))
      (consent--eval-error
       "collection manifest summary must be a string or #f"))
    (list :name key
          :category category
          :status status
          :source-kind source-kind
          :implementation-id implementation-id
          :primitive-overlay-library primitive-overlay-library
          :visibility visibility
          :layer layer
          :availability availability
          :availability-condition availability-condition
          :source-file source-file
          :aliases aliases
          :target target
          :exports exports
          :dependencies dependencies
          :origin 'built-in-seed
          :source-id (plist-get spec :source-id)
          :summary summary)))

(defun consent--library-collection-manifest-entries ()
  "Return collection-manifest metadata for repo-owned libraries."
  (or consent--library-collection-manifest-cache
      (setq
       consent--library-collection-manifest-cache
       (apply
        #'append
        (mapcar
         (lambda (spec)
           (mapcar
            (lambda (entry)
              (consent--collection-manifest-entry entry spec))
            (consent--proper-list-elements
             (consent--collection-manifest-library-value spec)
             "collection manifest entries")))
         (consent--library-collection-manifest-specs))))))

(defun consent--library-collection-manifest-entry (key)
  "Return collection-manifest metadata for library KEY, or nil."
  (seq-find
   (lambda (entry)
     (equal (plist-get entry :name) key))
   (consent--library-collection-manifest-entries)))

(defun consent--library-visibility (key)
  "Return KEY's public/internal visibility tier from manifests."
  (or (plist-get (consent--library-collection-manifest-entry key)
                 :visibility)
      'public))

(defun consent--library-visibility-internal-p (visibility)
  "Return non-nil when VISIBILITY requires internal-library posture."
  (memq visibility '(internal-runtime internal-agent-model)))

(defun consent--library-availability-condition-satisfied-p (condition)
  "Return non-nil when manifest availability CONDITION is satisfied."
  (cond
   ((or (null condition) (eq condition consent-false)) t)
   ((and (consp condition)
         (consent--symbol-named-p (car condition) "host")
         (consent--symbol-named-p (cadr condition) "emacs"))
    t)
   (t nil)))

(defun consent--library-entry-available-p (entry)
  "Return non-nil when manifest ENTRY is available on this host."
  (and entry
       (consent--library-availability-condition-satisfied-p
        (plist-get entry :availability-condition))))

(defun consent--library-internal-import-allowed-p (context)
  "Return non-nil when CONTEXT or source loading may import internals."
  (or consent--source-library-internal-imports-allowed
      (and context
           (condition-case nil
               (consent--eval-context-internal-libraries-allowed context)
             (args-out-of-range nil)))))

(defun consent--ensure-library-import-allowed (key context)
  "Signal when KEY is not importable in CONTEXT's current posture."
  (let ((visibility (consent--library-visibility key)))
    (when (and (consent--library-visibility-internal-p visibility)
               (not (consent--library-internal-import-allowed-p context)))
      (consent--eval-error
       "internal library import requires internal-libraries-allowed: %s"
       key))))

(defun consent--library-catalog-source-kind (key)
  "Return the manifest implementation source kind for library KEY."
  (plist-get (consent--library-collection-manifest-entry key)
             :source-kind))

(defun consent--library-catalog-private-context ()
  "Return a fresh context/environment pair for catalog export discovery."
  (require 'consent-eval)
  (let ((context
         (consent--new-eval-context
          '(:internal-libraries-allowed t)))
        (environment (consent-make-base-environment)))
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (consent--ensure-base-syntax context environment)
    (cons context environment)))

(defun consent--library-catalog-export-names (key)
  "Return exported binding names for cataloged library KEY."
  (let ((manifest-entry
         (consent--library-collection-manifest-entry key)))
    (or (plist-get manifest-entry :exports)
        (and (plist-get manifest-entry :target)
             (consent--library-catalog-export-names
              (plist-get manifest-entry :target)))
        (condition-case _
            (let* ((pair (consent--library-catalog-private-context))
                   (context (car pair))
                   (environment (cdr pair))
                   (library
                    (consent--resolve-library
                     (consent-read key)
                     context
                     environment)))
              (mapcar #'consent--library-binding-name
                      (consent--library-exports library)))
          (error nil)))))

(defun consent--library-catalog-aliases (key)
  "Return aliases that resolve to library KEY."
  (delq nil
        (mapcar
         (lambda (entry)
           (when (equal key (plist-get entry :target))
             (plist-get entry :name)))
         (consent--library-collection-manifest-entries))))

(defun consent--library-catalog-dependencies (key)
  "Return manifest dependency names for KEY when known."
  (let ((manifest-entry
         (consent--library-collection-manifest-entry key)))
    (and (plist-member manifest-entry :dependencies)
         (plist-get manifest-entry :dependencies))))

(defun consent--library-catalog-invalidate ()
  "Clear cached manifest-backed catalog entries."
  (setq consent--library-catalog-cache nil)
  (setq consent--library-collection-manifest-cache nil))

(defun consent--library-catalog-source-id (value)
  "Return VALUE normalized as a catalog source id."
  (cond
   ((stringp value) value)
   ((symbolp value) value)
   ((consent-symbol-p value) (intern (consent-symbol-name value)))
   (t (consent--eval-error "catalog source id must be a symbol or string"))))

(defun consent--library-catalog-field-form (fields name)
  "Return field form named NAME from manifest FIELDS."
  (seq-find
   (lambda (field)
     (and (consp field)
          (consent--symbol-named-p (car field) name)))
   fields))

(defun consent--library-catalog-manifest-field (fields name default)
  "Return NAME's value from manifest FIELDS, or DEFAULT."
  (let ((field (consent--library-catalog-field-form fields name)))
    (if field
        (cadr field)
      default)))

(defun consent--library-catalog-require-symbol (value description)
  "Return VALUE as an Emacs Lisp symbol, or signal DESCRIPTION."
  (cond
   ((symbolp value) value)
   ((consent-symbol-p value) (intern (consent-symbol-name value)))
   (t (consent--eval-error "%s must be a symbol" description))))

(defun consent--library-catalog-require-source-file (value)
  "Return VALUE when it is nil, Scheme #f, or a string."
  (cond
   ((or (null value) (eq value consent-false)) nil)
   ((stringp value) value)
   (t (consent--eval-error "catalog source-file must be a string or #f"))))

(defun consent--library-catalog-require-symbol-list (value description)
  "Return VALUE as a list of symbol names."
  (mapcar
   (lambda (entry)
     (consent--expect-symbol-name entry description))
   (consent--proper-list-elements value description)))

(defun consent--library-catalog-require-library-list (value description)
  "Return VALUE as a list of normalized library-name keys."
  (mapcar
   #'consent--library-name-key
   (consent--proper-list-elements value description)))

(defun consent--library-catalog-require-target (value)
  "Return VALUE as a normalized library-name key, or nil."
  (unless (or (null value) (eq value consent-false))
    (consent--library-name-key value)))

(defun consent--library-catalog-manifest-library (form origin source-id)
  "Validate manifest library FORM under ORIGIN and SOURCE-ID."
  (let ((parts (consent--proper-list-elements form "catalog library entry")))
    (unless (and parts (consent--symbol-named-p (car parts) "library"))
      (consent--eval-error "catalog entry must begin with library"))
    (let* ((fields (cdr parts))
           (name
            (consent--library-name-key
             (consent--library-catalog-manifest-field fields "name" nil)))
           (category
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "category" 'library)
             "catalog category"))
           (status
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "status" 'available)
             "catalog status"))
           (source-kind
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "source-kind" 'manifest)
             "catalog source-kind"))
           (visibility
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "visibility" 'public)
             "catalog visibility"))
           (source-file
            (consent--library-catalog-require-source-file
             (consent--library-catalog-manifest-field
              fields "source-file" nil)))
           (aliases
            (consent--library-catalog-require-library-list
             (consent--library-catalog-manifest-field fields "aliases" nil)
             "catalog aliases"))
           (target
            (consent--library-catalog-require-target
             (consent--library-catalog-manifest-field fields "target" nil)))
           (exports
            (consent--library-catalog-require-symbol-list
             (consent--library-catalog-manifest-field fields "exports" nil)
             "catalog exports"))
           (dependencies
            (consent--library-catalog-require-library-list
             (consent--library-catalog-manifest-field
              fields "dependencies" nil)
             "catalog dependencies"))
           (summary
            (consent--library-catalog-manifest-field fields "summary" nil)))
      (when (eq summary consent-false)
        (setq summary nil))
      (unless (or (null summary) (stringp summary))
        (consent--eval-error "catalog summary must be a string or #f"))
      (list :name name
            :category category
            :status status
            :source-kind source-kind
            :visibility visibility
            :source-file source-file
            :aliases aliases
            :target target
            :exports exports
            :dependencies dependencies
            :origin origin
            :source-id source-id
            :summary summary))))

(defun consent--library-catalog-parse-manifest (manifest origin source-id)
  "Validate MANIFEST and return catalog entries tagged with ORIGIN/SOURCE-ID."
  (let ((parts (consent--proper-list-elements
                manifest "library catalog manifest")))
    (unless (and parts (consent--symbol-named-p (car parts) "library-catalog"))
      (consent--eval-error
       "catalog manifest must begin with library-catalog"))
    (mapcar
     (lambda (form)
       (consent--library-catalog-manifest-library form origin source-id))
     (cdr parts))))

(defun consent--library-catalog-replace-source (sources source-id entries)
  "Return SOURCES with SOURCE-ID replaced by ENTRIES."
  (cons (cons source-id entries)
        (seq-remove
         (lambda (source)
           (equal (car source) source-id))
         sources)))

(defun consent--library-catalog-remove-source (sources source-id)
  "Return (REMOVED . SOURCES) after removing SOURCE-ID."
  (let ((removed nil)
        result)
    (dolist (source sources)
      (if (equal (car source) source-id)
          (setq removed t)
        (push source result)))
    (cons removed (nreverse result))))

(defun consent--library-catalog-source-id-datum (source-id)
  "Return SOURCE-ID as a Scheme-readable datum."
  (cond
   ((stringp source-id) source-id)
   ((symbolp source-id) (consent--syntax-symbol (symbol-name source-id)))
   ((consent-symbol-p source-id) source-id)
   ((null source-id) consent-false)
   (t source-id)))

(defun consent--library-catalog-source-record-for-names
    (kind source-id library-names)
  "Return a Scheme-readable catalog-source record for LIBRARY-NAMES."
  (list (consent--syntax-symbol "catalog-source")
        (list (consent--syntax-symbol "kind")
              (consent--syntax-symbol (symbol-name kind)))
        (list (consent--syntax-symbol "id")
              (consent--library-catalog-source-id-datum source-id))
        (list (consent--syntax-symbol "libraries") library-names)))

(defun consent--library-catalog-source-record (kind source-id entries)
  "Return a Scheme-readable catalog-source record."
  (consent--library-catalog-source-record-for-names
   kind
   source-id
   (mapcar
    (lambda (entry)
      (consent-read (plist-get entry :name)))
    entries)))

(defun consent--library-catalog-add-manifest (source-id manifest)
  "Add or replace ad-hoc catalog MANIFEST under SOURCE-ID."
  (let* ((normalized-id (consent--library-catalog-source-id source-id))
         (entries
          (consent--library-catalog-parse-manifest
           manifest 'ad-hoc-manifest normalized-id)))
    (setq consent--library-catalog-ad-hoc-manifests
          (consent--library-catalog-replace-source
           consent--library-catalog-ad-hoc-manifests
           normalized-id
           entries))
    (consent--library-catalog-invalidate)
    (consent--library-catalog-source-record
     'ad-hoc-manifest normalized-id entries)))

(defun consent--library-catalog-remove-manifest (source-id)
  "Remove ad-hoc catalog manifest SOURCE-ID."
  (let* ((normalized-id (consent--library-catalog-source-id source-id))
         (removed/sources
          (consent--library-catalog-remove-source
           consent--library-catalog-ad-hoc-manifests
           normalized-id)))
    (setq consent--library-catalog-ad-hoc-manifests (cdr removed/sources))
    (consent--library-catalog-invalidate)
    (car removed/sources)))

(defun consent--library-catalog-add-root (root manifest)
  "Add or replace explicit manifest ROOT with MANIFEST."
  (unless (stringp root)
    (consent--eval-error "catalog root must be a string"))
  (let ((entries
         (consent--library-catalog-parse-manifest
          manifest 'manifest-root root)))
    (setq consent--library-catalog-root-manifests
          (consent--library-catalog-replace-source
           consent--library-catalog-root-manifests
           root
           entries))
    (consent--library-catalog-invalidate)
    (consent--library-catalog-source-record 'manifest-root root entries)))

(defun consent--library-catalog-remove-root (root)
  "Remove explicit manifest ROOT."
  (unless (stringp root)
    (consent--eval-error "catalog root must be a string"))
  (let ((removed/sources
         (consent--library-catalog-remove-source
          consent--library-catalog-root-manifests
          root)))
    (setq consent--library-catalog-root-manifests (cdr removed/sources))
    (consent--library-catalog-invalidate)
    (car removed/sources)))

(defun consent--library-catalog-refresh ()
  "Clear manifest-backed catalog cache and diagnostics."
  (setq consent--library-catalog-diagnostics nil)
  (consent--library-catalog-invalidate)
  t)

(defun consent--library-catalog-entry (key)
  "Return manifest-backed catalog metadata for library KEY."
  (let* ((manifest-entry
          (consent--library-collection-manifest-entry key))
         (source-kind (consent--library-catalog-source-kind key))
         (source-file (consent--library-catalog-source-file key)))
    (list
     :name key
     :category (or (plist-get manifest-entry :category)
                   (consent--library-catalog-category key))
     :status (or (plist-get manifest-entry :status)
                 'implemented)
     :source-kind source-kind
     :implementation-id (plist-get manifest-entry :implementation-id)
     :primitive-overlay-library
     (plist-get manifest-entry :primitive-overlay-library)
     :visibility (consent--library-visibility key)
     :availability (or (plist-get manifest-entry :availability) 'required)
     :availability-condition
     (plist-get manifest-entry :availability-condition)
     :source-file source-file
     :aliases (if (plist-member manifest-entry :aliases)
                  (plist-get manifest-entry :aliases)
                (consent--library-catalog-aliases key))
     :target (plist-get manifest-entry :target)
     :exports (consent--library-catalog-export-names key)
     :dependencies (consent--library-catalog-dependencies key)
     :origin 'built-in-seed
     :source-id 'built-in-seed
     :summary (plist-get manifest-entry :summary))))

(defun consent--library-catalog-built-in-keys ()
  "Return built-in catalog keys from collection manifests."
  (let ((keys
         (delete-dups
          (copy-sequence
           (mapcar
            (lambda (entry)
              (plist-get entry :name))
            (consent--library-collection-manifest-entries))))))
    (sort keys #'string<)))

(defun consent--library-catalog-built-in-entries ()
  "Return built-in seed catalog entries."
  (mapcar #'consent--library-catalog-entry
          (consent--library-catalog-built-in-keys)))

(defun consent--library-catalog-source-entries (sources)
  "Return all catalog entries stored in SOURCES."
  (apply #'append (mapcar #'cdr sources)))

(defun consent--library-catalog-duplicate-diagnostic (entry previous)
  "Return duplicate-library diagnostic for ENTRY shadowed by PREVIOUS."
  (list (consent--syntax-symbol "catalog-diagnostic")
        (list (consent--syntax-symbol "kind")
              (consent--syntax-symbol "duplicate-library"))
        (list (consent--syntax-symbol "name")
              (consent-read (plist-get entry :name)))
        (list (consent--syntax-symbol "kept-source")
              (consent--library-catalog-source-id-datum
               (plist-get previous :source-id)))
        (list (consent--syntax-symbol "ignored-source")
              (consent--library-catalog-source-id-datum
               (plist-get entry :source-id)))))

(defun consent--library-catalog-deduplicate (entries)
  "Return ENTRIES with first-wins precedence and diagnostics."
  (let ((seen nil)
        result
        diagnostics)
    (dolist (entry entries)
      (let* ((name (plist-get entry :name))
             (previous (assoc name seen)))
        (if previous
            (push
             (consent--library-catalog-duplicate-diagnostic
              entry
              (cdr previous))
             diagnostics)
          (push (cons name entry) seen)
          (push entry result))))
    (setq consent--library-catalog-diagnostics (nreverse diagnostics))
    (nreverse result)))

(defun consent--library-catalog-candidate-entries ()
  "Return catalog input entries in precedence order."
  (append
   (consent--library-catalog-source-entries
    consent--library-catalog-ad-hoc-manifests)
   (consent--library-catalog-source-entries
    consent--library-catalog-root-manifests)
   (consent--library-catalog-built-in-entries)))

(defun consent--library-catalog-entries ()
  "Return manifest-backed catalog metadata for repo-owned libraries."
  (or consent--library-catalog-cache
      (setq
       consent--library-catalog-cache
       (consent--library-catalog-deduplicate
        (consent--library-catalog-candidate-entries)))))

(defun consent--library-catalog-sources ()
  "Return Scheme-readable catalog source records."
  (append
   (mapcar
    (lambda (source)
      (consent--library-catalog-source-record
       'ad-hoc-manifest
       (car source)
       (cdr source)))
    consent--library-catalog-ad-hoc-manifests)
   (mapcar
    (lambda (source)
      (consent--library-catalog-source-record
       'manifest-root
       (car source)
       (cdr source)))
    consent--library-catalog-root-manifests)
   (list
    (consent--library-catalog-source-record-for-names
     'built-in-seed
     'built-in-seed
     (mapcar #'consent-read
             (consent--library-catalog-built-in-keys))))))

(defun consent--library-catalog-diagnostics ()
  "Return diagnostics from the most recent catalog build."
  (unless consent--library-catalog-cache
    (consent--library-catalog-entries))
  consent--library-catalog-diagnostics)

(defun consent--library-catalog-lookup (library-name)
  "Return catalog metadata for LIBRARY-NAME, or nil when absent."
  (let ((key (if (stringp library-name)
                 library-name
               (consent--library-name-key library-name))))
    (seq-find
     (lambda (entry)
       (equal (plist-get entry :name) key))
     (consent--library-catalog-entries))))

(defun consent--library-catalog-search (query)
  "Return catalog entries whose name, alias, export, or category matches QUERY."
  (let ((needle (downcase query)))
    (seq-filter
     (lambda (entry)
       (let ((haystack
              (mapconcat
               (lambda (item)
                 (cond
                  ((stringp item) item)
                  ((symbolp item) (symbol-name item))
                  (t (format "%S" item))))
               (delq nil
                     (append
                      (list (plist-get entry :name)
                            (symbol-name (plist-get entry :category))
                            (symbol-name (plist-get entry :source-kind))
                            (symbol-name (plist-get entry :visibility))
                            (symbol-name (plist-get entry :status))
                            (plist-get entry :target)
                            (plist-get entry :source-file)
                            (plist-get entry :source-id)
                            (plist-get entry :summary))
                      (plist-get entry :aliases)
                      (plist-get entry :exports)
                      (plist-get entry :dependencies)))
               " ")))
         (string-match-p (regexp-quote needle) (downcase haystack))))
     (consent--library-catalog-entries))))

(defun consent--library-catalog-runtime-source-files ()
  "Return runtime source-file paths derived from the library catalog."
  (let ((files
         (append
          '("consent/base-prelude.scm"
            "consent/base-syntax.scm")
          (delq nil
                (mapcar
                 (lambda (entry)
                   (plist-get entry :source-file))
                 (consent--library-catalog-built-in-entries))))))
    (delete-dups files)))

(defun consent--nonnegative-exact-integer-datum-p (datum)
  "Return non-nil if DATUM is an exact non-negative integer datum."
  (and (consent-number-p datum)
       (eq (consent-number-kind datum) 'integer)
       (eq (consent-number-exactness datum) 'exact)
       (>= (consent-number-value datum) 0)))

(defun consent--library-name-p (datum)
  "Return non-nil if DATUM is a valid R7RS library name datum."
  (and (consp datum)
       (let ((parts (consent--proper-list-elements-maybe datum)))
         (and parts
              (cl-every
               (lambda (part)
                 (or (consent-symbol-p part)
                     (consent--nonnegative-exact-integer-datum-p part)))
               parts)))))

(defun consent--library-name-key (name)
  "Return the registry key for library NAME."
  (unless (consent--library-name-p name)
    (consent--eval-error
     "invalid library name: %s" (consent-value->external name)))
  (consent-datum->external (consent--strip-identifiers name)))

(defun consent--current-environment-cell (environment name)
  "Return NAME's cell in ENVIRONMENT's current frame, or nil."
  (let ((cell (gethash name
                       (consent--environment-bindings environment)
                       consent--missing-cell)))
    (unless (eq cell consent--missing-cell)
      cell)))

(defun consent--current-syntax-binding (syntax-environment name)
  "Return NAME's binding in SYNTAX-ENVIRONMENT's current frame, or nil."
  (let ((binding (gethash
                  name
                  (consent--syntax-environment-bindings
                   syntax-environment)
                  consent--missing-cell)))
    (unless (eq binding consent--missing-cell)
      binding)))

(defun consent--form-named-p (form name)
  "Return non-nil when FORM is a list beginning with identifier NAME."
  (and (consp form)
       (consent--symbol-named-p (car form) name)))

(defun consent--import-form-p (form)
  "Return non-nil if FORM is an import declaration."
  (consent--form-named-p form "import"))

(defun consent--define-library-form-p (form)
  "Return non-nil if FORM is a define-library form."
  (consent--form-named-p form "define-library"))

(defun consent--library-binding-with-name (binding name)
  "Return BINDING renamed to local NAME."
  (consent--make-library-binding
   name
   (consent--library-binding-kind binding)
   (consent--library-binding-object binding)
   (consent--library-binding-library-key binding)))

(defun consent--same-library-binding-p (left right)
  "Return non-nil if LEFT and RIGHT identify the same imported binding."
  (and (consent--library-binding-p left)
       (consent--library-binding-p right)
       (eq (consent--library-binding-kind left)
           (consent--library-binding-kind right))
       (eq (consent--library-binding-object left)
           (consent--library-binding-object right))))

(defun consent--snapshot-library-bindings
    (value-environment syntax-environment library-key)
  "Return exported bindings from VALUE-ENVIRONMENT and SYNTAX-ENVIRONMENT."
  (let (exports)
    (maphash
     (lambda (name cell)
       (push (consent--make-library-binding
              name 'value cell library-key)
             exports))
     (consent--environment-bindings value-environment))
    (maphash
     (lambda (name transformer)
       (push (consent--make-library-binding
              name 'syntax transformer library-key)
             exports))
     (consent--syntax-environment-bindings syntax-environment))
    (nreverse exports)))

(defun consent--register-scheme-base-library
    (context environment)
  "Register the builtin `(scheme base)' library in CONTEXT."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash consent--scheme-base-library-key registry)
      (let* ((use-current-environment
              (consent--environment-cell environment "+"))
             (base-environment
              (if use-current-environment
                  environment
                (consent-make-base-environment)))
             (base-context
              (if use-current-environment
                  context
                (consent--new-eval-context nil))))
        (unless use-current-environment
          (consent--ensure-base-syntax
           base-context base-environment))
        (let* ((syntax-environment
                (consent--eval-context-syntax-environment
                 base-context))
               (exports
                (consent--snapshot-library-bindings
                 base-environment
                 syntax-environment
                 consent--scheme-base-library-key)))
          (puthash
           consent--scheme-base-library-key
           (consent--make-library
            (list (consent--syntax-symbol "scheme")
                  (consent--syntax-symbol "base"))
            consent--scheme-base-library-key
            exports
            base-environment
            syntax-environment)
           registry))))))

(defun consent--manifest-source-library-file (source-file)
  "Return absolute path for seed-root-relative manifest SOURCE-FILE."
  (expand-file-name source-file consent-library-seed-directory))

(defun consent--manifest-source-library-source (source-file key)
  "Return source text for seed-root-relative SOURCE-FILE owned by KEY."
  (let ((path (consent--manifest-source-library-file source-file)))
    (unless (file-readable-p path)
      (consent--eval-error
       "manifest source library file is not readable for %s: %s"
       key path))
    (with-temp-buffer
      (insert-file-contents path)
      (buffer-string))))

(defun consent--register-manifest-source-library
    (entry context environment)
  "Register the source library described by manifest ENTRY."
  (let ((key (plist-get entry :name))
        (source-file (plist-get entry :source-file))
        (exports (plist-get entry :exports))
        (overlay-library (plist-get entry :primitive-overlay-library)))
    (unless source-file
      (consent--eval-error
       "manifest source library has no source-file: %s"
       key))
    (unless (gethash key (consent--eval-context-libraries context))
      (consent--register-source-library
       (consent--manifest-source-library-source source-file key)
       context
       environment)
      (when overlay-library
        (let ((overlay-entry
               (consent--library-collection-manifest-entry overlay-library)))
          (unless overlay-entry
            (consent--eval-error
             "manifest primitive overlay library is not declared: %s"
             overlay-library))
         (consent--register-library-primitive-bindings
          key
          (consent--manifest-exported-primitive-specs overlay-entry)
          context)))
      (when exports
        (let ((library (gethash key (consent--eval-context-libraries context))))
          (unless library
            (consent--eval-error
             "manifest source library registered a different name: %s"
             key))
          (setf (consent--library-exports library)
                (consent--filter-library-exports
                 (consent--library-exports library)
                 exports
                 key)))))))

(defun consent--manifest-primitive-implementation-specs (entry)
  "Return primitive specs for manifest primitive implementation ENTRY."
  (let ((implementation-id (plist-get entry :implementation-id)))
    (pcase implementation-id
      ('scheme-char
       `(("char-alphabetic?" ,#'consent--primitive-char-alphabetic? 1 1)
         ("char-ci<=?" ,#'consent--primitive-char-ci<=? 2 nil)
         ("char-ci<?" ,#'consent--primitive-char-ci<? 2 nil)
         ("char-ci=?" ,#'consent--primitive-char-ci=? 2 nil)
         ("char-ci>=?" ,#'consent--primitive-char-ci>=? 2 nil)
         ("char-ci>?" ,#'consent--primitive-char-ci>? 2 nil)
         ("char-downcase" ,#'consent--primitive-char-downcase 1 1)
         ("char-foldcase" ,#'consent--primitive-char-foldcase 1 1)
         ("char-lower-case?" ,#'consent--primitive-char-lower-case? 1 1)
         ("char-numeric?" ,#'consent--primitive-char-numeric? 1 1)
         ("char-upcase" ,#'consent--primitive-char-upcase 1 1)
         ("char-upper-case?" ,#'consent--primitive-char-upper-case? 1 1)
         ("char-whitespace?" ,#'consent--primitive-char-whitespace? 1 1)
         ("digit-value" ,#'consent--primitive-digit-value 1 1)
         ("string-ci<=?" ,#'consent--primitive-string-ci<=? 2 nil)
         ("string-ci<?" ,#'consent--primitive-string-ci<? 2 nil)
         ("string-ci=?" ,#'consent--primitive-string-ci=? 2 nil)
         ("string-ci>=?" ,#'consent--primitive-string-ci>=? 2 nil)
         ("string-ci>?" ,#'consent--primitive-string-ci>? 2 nil)
         ("string-downcase" ,#'consent--primitive-string-downcase 1 1)
         ("string-foldcase" ,#'consent--primitive-string-foldcase 1 1)
         ("string-upcase" ,#'consent--primitive-string-upcase 1 1)))
      ('scheme-complex
       `(("angle" ,#'consent--primitive-angle 1 1)
         ("imag-part" ,#'consent--primitive-imag-part 1 1)
         ("magnitude" ,#'consent--primitive-magnitude 1 1)
         ("make-polar" ,#'consent--primitive-make-polar 2 2)
         ("make-rectangular" ,#'consent--primitive-make-rectangular 2 2)
         ("real-part" ,#'consent--primitive-real-part 1 1)))
      ('scheme-cxr (consent--cxr-primitive-specs entry))
      ('scheme-eval
       `(("environment" ,#'consent--primitive-environment 1 nil)
         ("eval" ,#'consent--primitive-eval 2 2)))
      ('scheme-file
       `(("call-with-input-file" ,#'consent--primitive-call-with-input-file
          2 2)
         ("call-with-output-file" ,#'consent--primitive-call-with-output-file
          2 2)
         ("delete-file" ,#'consent--primitive-delete-file 1 1)
         ("file-exists?" ,#'consent--primitive-file-exists? 1 1)
         ("open-binary-input-file" ,#'consent--primitive-open-binary-input-file
          1 1)
         ("open-binary-output-file" ,#'consent--primitive-open-binary-output-file
          1 1)
         ("open-input-file" ,#'consent--primitive-open-input-file 1 1)
         ("open-output-file" ,#'consent--primitive-open-output-file 1 1)
         ("with-input-from-file" ,#'consent--primitive-with-input-from-file
          2 2)
         ("with-output-to-file" ,#'consent--primitive-with-output-to-file
          2 2)))
      ('scheme-inexact
       `(("acos" ,#'consent--primitive-acos 1 1)
         ("asin" ,#'consent--primitive-asin 1 1)
         ("atan" ,#'consent--primitive-atan 1 2)
         ("cos" ,#'consent--primitive-cos 1 1)
         ("exp" ,#'consent--primitive-exp 1 1)
         ("finite?" ,#'consent--primitive-finite? 1 1)
         ("infinite?" ,#'consent--primitive-infinite? 1 1)
         ("log" ,#'consent--primitive-log 1 2)
         ("nan?" ,#'consent--primitive-nan? 1 1)
         ("sin" ,#'consent--primitive-sin 1 1)
         ("sqrt" ,#'consent--primitive-sqrt 1 1)
         ("tan" ,#'consent--primitive-tan 1 1)))
      ('scheme-load
       `(("load" ,#'consent--primitive-load 1 2)))
      ('scheme-process-context
       (append
        `(("command-line" ,#'consent--primitive-command-line 0 0))
        (mapcar #'consent--policy-denied-spec
                '("emergency-exit" "exit"))
        `(("get-environment-variable"
           ,#'consent--primitive-get-environment-variable 1 1)
          ("get-environment-variables"
           ,#'consent--primitive-get-environment-variables 0 0))))
      ('scheme-read
       `(("read" ,#'consent--primitive-read 0 1)))
      ('scheme-repl
       `(("interaction-environment"
          ,#'consent--primitive-interaction-environment 0 0)))
      ('scheme-time
       `(("current-jiffy" ,#'consent--primitive-current-jiffy 0 0)
         ("current-second" ,#'consent--primitive-current-second 0 0)
         ("jiffies-per-second"
          ,#'consent--primitive-jiffies-per-second 0 0)))
      ('scheme-write
       `(("display" ,#'consent--primitive-display 1 2)
         ("write" ,#'consent--primitive-write 1 2)
         ("write-shared" ,#'consent--primitive-write-shared 1 2)
         ("write-simple" ,#'consent--primitive-write-simple 1 2)))
      ('agent-io (consent-agent-io-primitive-specs))
      ('agent-approval (consent-approval-primitive-specs))
      ('agent-debugger (consent-debugger-primitive-specs))
      ('agent-helper (consent-helper-primitive-specs))
      ('agent-job (consent-job-primitive-specs))
      ('agent-test (consent-test-primitive-specs))
      ('agent-memory (consent--memory-adapter-primitive-specs))
      ('agent-plan (consent-plan-primitive-specs))
      ('agent-models (consent-models-primitive-specs))
      ('agent-context (consent-context-primitive-specs))
      ('agent-reflect (consent-reflect-primitive-specs))
      ('agent-redaction (consent-redaction-primitive-specs))
      ('agent-session (consent--session-adapter-primitive-specs))
      ('consent-capability (consent-capability-primitive-specs))
      ('cli-process-host (consent--cli-process-host-primitive-specs))
      ('emacs-capability
       (consent-emacs-capability-primitive-specs
        (plist-get entry :name)))
      (_
       (consent--eval-error
        "manifest primitive library has no implementation id: %s"
        (plist-get entry :name))))))

(defun consent--manifest-filter-primitive-specs (entry primitive-specs)
  "Return PRIMITIVE-SPECS reduced to manifest ENTRY exports."
  (let ((exports (plist-get entry :exports)))
    (if exports
        (seq-filter
         (lambda (spec)
           (member (car spec) exports))
         primitive-specs)
      primitive-specs)))

(defun consent--manifest-exported-primitive-specs (entry)
  "Return primitive specs for ENTRY after applying manifest exports."
  (consent--manifest-filter-primitive-specs
   entry
   (consent--manifest-primitive-implementation-specs entry)))

(defun consent--manifest-implementation-routable-p (entry)
  "Return non-nil when manifest ENTRY has an implementation route."
  (pcase (plist-get entry :source-kind)
    ('primitive
     (condition-case nil
         (progn
           (consent--manifest-primitive-implementation-specs entry)
           t)
       (consent-eval-error nil)))
    ('derived
     (eq (plist-get entry :implementation-id) 'scheme-r5rs))
    (_ nil)))

(defun consent--register-manifest-implementation-library
    (entry context environment)
  "Register primitive or derived library described by manifest ENTRY."
  (let ((key (plist-get entry :name))
        (implementation-id (plist-get entry :implementation-id)))
    (pcase (plist-get entry :source-kind)
      ('primitive
       (consent--register-primitive-library
        key
        (consent--manifest-exported-primitive-specs entry)
        context))
      ('derived
       (pcase implementation-id
         ('scheme-r5rs
          (consent--register-r5rs-library key context environment))
         (_
          (consent--eval-error
           "manifest derived library has no implementation id: %s"
           key))))
      (_
       (consent--eval-error
        "manifest library is not primitive or derived: %s"
        key)))))

(defun consent--manifest-library-routable-p (entry)
  "Return non-nil when manifest ENTRY describes an import route."
  (and entry
       (or (plist-get entry :target)
           (plist-get entry :source-file)
           (memq (plist-get entry :source-kind)
                 '(base-snapshot))
           (consent--manifest-implementation-routable-p entry))))

(defun consent--register-source-library
    (source context environment)
  "Evaluate one define-library SOURCE into CONTEXT."
  (let ((max-lisp-eval-depth (max max-lisp-eval-depth 4096))
        (consent--source-library-internal-imports-allowed t)
        (forms (consent-read-all source)))
    (unless (= (length forms) 1)
      (consent--eval-error
       "source library must contain exactly one form"))
    (consent--eval-define-library
     (car forms)
     environment
     context)))

(defun consent--find-library-export (name exports)
  "Return export named NAME from EXPORTS, or nil."
  (cl-find name exports
           :key #'consent--library-binding-name
           :test #'equal))

(defun consent--register-subset-library
    (key export-names context environment)
  "Register KEY as a subset of `(scheme base)' EXPORT-NAMES."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (consent--resolve-library
               (consent-read consent--scheme-base-library-key)
               context
               environment))
             (base-exports
              (consent--library-exports base-library))
             (exports
              (mapcar
               (lambda (name)
                 (or (consent--find-library-export
                      name base-exports)
                     (consent--eval-error
                      "standard library binding is not available: %s"
                      name)))
               export-names)))
        (puthash
         key
         (consent--make-library
          (consent-read key)
          key
          exports
          (consent--library-value-environment base-library)
          (consent--library-syntax-environment base-library))
         registry)))))

(defun consent--register-primitive-library
    (key primitive-specs context)
  "Register KEY with PRIMITIVE-SPECS.
Each spec has (NAME FUNCTION MINIMUM-ARITY MAXIMUM-ARITY)."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash key registry)
      (let ((value-environment (consent-make-empty-environment))
            (syntax-environment
             (consent--make-empty-syntax-environment)))
        (dolist (spec primitive-specs)
          (consent--define-primitive
           value-environment
           (nth 0 spec)
           (nth 1 spec)
           (nth 2 spec)
           (nth 3 spec)))
        (puthash
         key
         (consent--make-library
          (consent-read key)
          key
          (consent--snapshot-library-bindings
           value-environment syntax-environment key)
          value-environment
          syntax-environment)
         registry)))))

(defun consent--library-exports-with-binding (exports binding)
  "Return EXPORTS with BINDING replacing the same-named export."
  (let ((name (consent--library-binding-name binding))
        (replaced nil)
        (result nil))
    (dolist (export exports)
      (if (equal (consent--library-binding-name export) name)
          (progn
            (setq replaced t)
            (push binding result))
        (push export result)))
    (unless replaced
      (push binding result))
    (nreverse result)))

(defun consent--register-library-primitive-bindings
    (key primitive-specs context)
  "Overlay PRIMITIVE-SPECS onto the already registered source library KEY."
  (let* ((registry (consent--eval-context-libraries context))
         (library (gethash key registry)))
    (unless library
      (consent--eval-error "source library is not registered: %s" key))
    (let ((value-environment
           (consent--library-value-environment library))
          (exports (consent--library-exports library)))
      (dolist (spec primitive-specs)
        (let ((name (nth 0 spec)))
          (consent--define-primitive
           value-environment
           name
           (nth 1 spec)
           (nth 2 spec)
           (nth 3 spec))
          (setq exports
                (consent--library-exports-with-binding
                 exports
                 (consent--make-library-binding
                  name
                  'value
                  (consent--environment-cell value-environment name)
                  key)))))
      (setf (consent--library-exports library) exports))))

(defun consent--cxr-primitive (name)
  "Return a primitive procedure implementation for composed accessor NAME."
  (let ((steps (reverse (string-to-list
                         (substring name 1 (1- (length name)))))))
    (lambda (arguments _context)
      (let ((value (car arguments)))
        (dolist (step steps)
          (setq value
                (if (= step ?a)
                    (consent--primitive-car (list value) nil)
                  (consent--primitive-cdr (list value) nil))))
        value))))

(defun consent--cxr-primitive-specs (entry)
  "Return primitive specs for manifest CXR library ENTRY."
  (mapcar
   (lambda (name)
     (list name (consent--cxr-primitive name) 1 1))
   (plist-get entry :exports)))

(defun consent--policy-denied-spec (name)
  "Return a primitive spec for default-denied host effect NAME."
  (list name
        (lambda (_arguments context)
          (consent--policy-denied name context))
        0
        nil))

(defun consent--register-r5rs-library (key context environment)
  "Register the practical `(scheme r5rs)' compatibility library KEY."
  (let ((registry (consent--eval-context-libraries context)))
    (unless (gethash key registry)
      (let* ((base-library
              (consent--resolve-library
               (consent-read consent--scheme-base-library-key)
               context
               environment))
             (exports (copy-sequence (consent--library-exports
                                       base-library)))
             (inexact-binding
              (consent--find-library-export "inexact" exports))
             (exact-binding
              (consent--find-library-export "exact" exports)))
        (push (consent--library-binding-with-name
               inexact-binding "exact->inexact")
              exports)
        (push (consent--library-binding-with-name
               exact-binding "inexact->exact")
              exports)
        (puthash
         key
         (consent--make-library
          (consent-read key)
          key
          (nreverse exports)
          (consent--library-value-environment base-library)
          (consent--library-syntax-environment base-library))
         registry)))))

(defun consent--filter-library-exports (exports export-names key)
  "Return EXPORTS narrowed to EXPORT-NAMES for alias library KEY."
  (dolist (name export-names)
    (unless (consent--find-library-export name exports)
      (consent--eval-error
       "alias export is not available in %s: %s" key name)))
  (cl-remove-if-not
   (lambda (binding)
     (member (consent--library-binding-name binding) export-names))
   exports))

(defun consent--library-alias-field (spec field)
  "Return FIELD from alias SPEC, or nil when absent."
  (cdr (assq field spec)))

(defun consent--register-library-alias (spec context environment)
  "Register alias SPEC using its target library and optional exports."
  (let* ((key (consent--library-alias-field spec :alias))
         (target-key (consent--library-alias-field spec :target))
         (export-names-entry (assq :exports spec)))
    (unless key
      (consent--eval-error "library alias has no alias name: %S" spec))
    (unless target-key
      (consent--eval-error "library alias has no target: %s" key))
    (unless (gethash key (consent--eval-context-libraries context))
      (let* ((target-library
              (consent--resolve-library
               (consent-read target-key) context environment))
             (target-exports (consent--library-exports target-library)))
      (puthash
       key
       (consent--make-library
        (consent-read key)
        key
        (if export-names-entry
            (consent--filter-library-exports
             target-exports (cdr export-names-entry) key)
          target-exports)
        (consent--library-value-environment target-library)
        (consent--library-syntax-environment target-library))
       (consent--eval-context-libraries context))))))

(defun consent--manifest-library-alias-spec (entry)
  "Return alias registration metadata for manifest ENTRY."
  (let ((key (plist-get entry :name))
        (target (plist-get entry :target))
        (exports (plist-get entry :exports)))
    (unless target
      (consent--eval-error "manifest alias has no target: %s" key))
    (delq nil
          (list (cons :alias key)
                (cons :target target)
                (and exports (cons :exports exports))))))

(defun consent--library-available-p (name context _environment)
  "Return non-nil if NAME can be imported."
  (let* ((key (consent--library-name-key name))
         (entry (consent--library-collection-manifest-entry key)))
    (and
     (or (not (consent--library-visibility-internal-p
               (consent--library-visibility key)))
         (consent--library-internal-import-allowed-p context))
     (or (not entry)
         (consent--library-entry-available-p entry))
     (or (consent--manifest-library-routable-p entry)
         (and (gethash key (consent--eval-context-libraries context))
              t)))))

(defun consent--resolve-library (name context environment)
  "Return library NAME from CONTEXT, registering builtins when needed."
  (let* ((key (consent--library-name-key name))
         (entry (consent--library-collection-manifest-entry key)))
    (consent--ensure-library-import-allowed key context)
    (when (and entry (not (consent--library-entry-available-p entry)))
      (consent--eval-error
       "optional library is unavailable on this host: %s"
       key))
    (unless (gethash key (consent--eval-context-libraries context))
      (cond
       ((null entry)
        nil)
       ((plist-get entry :target)
        (consent--register-library-alias
         (consent--manifest-library-alias-spec entry)
         context
         environment))
       ((eq (plist-get entry :source-kind) 'base-snapshot)
        (consent--register-scheme-base-library context environment))
       ((plist-get entry :source-file)
        (consent--register-manifest-source-library entry context environment))
       ((memq (plist-get entry :source-kind) '(primitive derived))
        (consent--register-manifest-implementation-library
         entry
         context
         environment))
       (t
        (consent--eval-error
         "library has no manifest registration strategy: %s"
         key))))
    (or (gethash key (consent--eval-context-libraries context))
        (consent--eval-error "unknown library: %s" key))))

(defun consent--source-library-environment (key)
  "Return a private value environment for source library KEY."
  (or (gethash key consent--source-library-environments)
      (progn
        (require 'consent-eval)
        (let ((context (consent--new-eval-context nil))
              (environment (consent-make-base-environment)))
          (setf (consent--eval-context-interaction-environment context)
                environment)
          (consent--ensure-base-syntax context environment)
          (consent--resolve-library (consent-read key) context environment)
          (let* ((library
                  (gethash key (consent--eval-context-libraries context)))
                 (value-environment
                  (and library
                       (consent--library-value-environment library))))
            (unless value-environment
              (consent--eval-error
               "source library is not registered: %s" key))
            (puthash key value-environment
                     consent--source-library-environments)
            value-environment)))))

(defun consent--source-library-procedure (key name)
  "Return source-backed procedure NAME from source library KEY."
  (let* ((cache-key (cons key name))
         (cached (gethash cache-key consent--source-library-procedures)))
    (or cached
        (let ((procedure
               (consent--environment-ref
                (consent--source-library-environment key)
                name)))
          (puthash cache-key procedure consent--source-library-procedures)
          procedure))))

(defun consent--source-library-call (key name &rest arguments)
  "Call source-backed procedure NAME from library KEY with ARGUMENTS."
  (let ((context
         (consent--new-eval-context consent--source-library-call-options))
        (environment (consent--source-library-environment key)))
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (consent--apply-procedure
     (consent--source-library-procedure key name)
     arguments
     context
     nil)))

(defun consent--import-binding-local-name (binding)
  "Return BINDING's local import name."
  (consent--library-binding-name binding))

(defun consent--find-import-binding (name bindings)
  "Return import binding named NAME from BINDINGS, or nil."
  (cl-find name bindings
           :key #'consent--import-binding-local-name
           :test #'equal))

(defun consent--ensure-import-names-present
    (names bindings description)
  "Signal if any NAMES are absent from BINDINGS for DESCRIPTION."
  (dolist (name names)
    (unless (consent--find-import-binding name bindings)
      (consent--eval-error
       "%s import name not found: %s" description name))))

(defun consent--ensure-compatible-import-bindings (bindings)
  "Return BINDINGS after checking for duplicate incompatible names."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (binding bindings)
      (let* ((name (consent--library-binding-name binding))
             (previous (gethash name seen)))
        (cond
         ((null previous)
          (puthash name binding seen)
          (push binding result))
         ((consent--same-library-binding-p previous binding))
         (t
          (consent--eval-error
           "conflicting imports for identifier: %s" name)))))
    (nreverse result)))

(defun consent--import-modifier-identifiers (forms description)
  "Return FORMS as identifier name strings for DESCRIPTION."
  (mapcar
   (lambda (form)
     (consent--expect-symbol-name form description))
   forms))

(defun consent--resolve-import-set
    (import-set context environment)
  "Resolve IMPORT-SET to a list of library bindings."
  (cond
   ((consent--library-name-p import-set)
    (copy-sequence
     (consent--library-exports
      (consent--resolve-library import-set context environment))))
   ((consp import-set)
    (let* ((parts (consent--proper-list-elements
                   import-set "import set"))
           (operator (car parts)))
      (cond
       ((consent--symbol-named-p operator "only")
        (unless (>= (length parts) 2)
          (consent--eval-error "only import set requires an import set"))
        (let* ((bindings
                (consent--resolve-import-set
                 (cadr parts) context environment))
               (names
                (consent--import-modifier-identifiers
                 (cddr parts) "only")))
          (consent--ensure-import-names-present names bindings "only")
          (cl-remove-if-not
           (lambda (binding)
             (member (consent--library-binding-name binding)
                     names))
           bindings)))
       ((consent--symbol-named-p operator "except")
        (unless (>= (length parts) 2)
          (consent--eval-error
           "except import set requires an import set"))
        (let* ((bindings
                (consent--resolve-import-set
                 (cadr parts) context environment))
               (names
                (consent--import-modifier-identifiers
                 (cddr parts) "except")))
          (consent--ensure-import-names-present names bindings "except")
          (cl-remove-if
           (lambda (binding)
             (member (consent--library-binding-name binding)
                     names))
           bindings)))
       ((consent--symbol-named-p operator "prefix")
        (unless (= (length parts) 3)
          (consent--eval-error
           "prefix import set requires an import set and prefix"))
        (let ((prefix
               (consent--expect-symbol-name
                (caddr parts) "prefix identifier")))
          (mapcar
           (lambda (binding)
             (consent--library-binding-with-name
              binding
              (concat prefix
                      (consent--library-binding-name binding))))
           (consent--resolve-import-set
            (cadr parts) context environment))))
       ((consent--symbol-named-p operator "rename")
        (unless (>= (length parts) 2)
          (consent--eval-error
           "rename import set requires an import set"))
        (let* ((bindings
                (consent--resolve-import-set
                 (cadr parts) context environment))
               (renames
                (mapcar
                 (lambda (rename-form)
                   (let ((rename-parts
                          (consent--proper-list-elements
                           rename-form "rename pair")))
                     (unless (= (length rename-parts) 2)
                       (consent--eval-error
                        "rename pair requires old and new identifiers"))
                     (cons
                      (consent--expect-symbol-name
                       (car rename-parts) "rename old identifier")
                      (consent--expect-symbol-name
                       (cadr rename-parts) "rename new identifier"))))
                 (cddr parts)))
               (old-names (mapcar #'car renames)))
          (consent--ensure-import-names-present
           old-names bindings "rename")
          (mapcar
           (lambda (binding)
             (let ((rename
                    (assoc (consent--library-binding-name binding)
                           renames)))
               (if rename
                   (consent--library-binding-with-name
                    binding (cdr rename))
                 binding)))
           bindings)))
       (t
        (consent--eval-error
         "invalid import set: %s"
         (consent-value->external import-set))))))
   (t
    (consent--eval-error
     "invalid import set: %s"
     (consent-value->external import-set)))))

(defun consent--install-imported-binding
    (binding value-environment syntax-environment)
  "Install one imported BINDING into VALUE-ENVIRONMENT or SYNTAX-ENVIRONMENT."
  (let ((name (consent--library-binding-name binding))
        (kind (consent--library-binding-kind binding))
        (object (consent--library-binding-object binding))
        (library-key (consent--library-binding-library-key binding)))
    (pcase kind
      ('value
       (let ((existing
              (consent--current-environment-cell
               value-environment name)))
         (cond
         ((null existing)
           (puthash name object
                    (consent--environment-bindings value-environment)))
          ((equal library-key consent--scheme-base-library-key)
           ;; Programs commonly import `(scheme base)' more than once while
           ;; bootstrapping derived libraries.  Reinstalling the same base name
           ;; is benign and keeps later import-set processing simple.
           (puthash name object
                    (consent--environment-bindings value-environment)))
          ((eq existing object))
          (t
           (consent--eval-error
            "conflicting import for identifier: %s" name))))
       (puthash name t
                (consent--environment-imported-bindings
                 value-environment)))
      ('syntax
       (let ((existing
              (consent--current-syntax-binding
               syntax-environment name)))
         (cond
          ((or (null existing)
               (equal library-key consent--scheme-base-library-key))
           (puthash name object
                    (consent--syntax-environment-bindings
                     syntax-environment)))
          ((eq existing object))
          (t
           (consent--eval-error
            "conflicting syntax import for identifier: %s" name))))
       (puthash name t
                (consent--syntax-environment-imported-bindings
                 syntax-environment)))
      (_
       (consent--eval-error
        "unsupported library binding kind: %S" kind)))))

(defun consent--install-import-set
    (import-set value-environment syntax-environment context)
  "Resolve and install IMPORT-SET."
  (dolist (binding
           (consent--ensure-compatible-import-bindings
            (consent--resolve-import-set
             import-set context value-environment)))
    (consent--install-imported-binding
     binding value-environment syntax-environment)))

(defun consent--eval-import (form environment context)
  "Evaluate top-level or library import declaration FORM."
  (let ((parts (consent--proper-list-elements
                form "import declaration")))
    (unless (>= (length parts) 2)
      (consent--eval-error
       "import requires at least one import set"))
    (dolist (import-set (cdr parts))
      (consent--install-import-set
       import-set
       environment
       (consent--eval-context-syntax-environment context)
       context))
    consent-unspecified))

(defun consent--export-specs (forms)
  "Return export specs parsed from FORMS as (INTERNAL . EXTERNAL)."
  (let (specs)
    (dolist (form forms)
      (cond
       ((consent--identifier-datum-p form)
        (let ((name (consent--expect-symbol-name
                     form "export identifier")))
          (push (cons name name) specs)))
       ((consent--form-named-p form "rename")
        (let ((parts (consent--proper-list-elements
                      form "export rename")))
          (unless (= (length parts) 3)
            (consent--eval-error
             "export rename requires internal and external identifiers"))
          (push
           (cons
            (consent--expect-symbol-name
             (cadr parts) "export internal identifier")
            (consent--expect-symbol-name
             (caddr parts) "export external identifier"))
           specs)))
       (t
        (consent--eval-error
         "invalid export spec: %s"
         (consent-value->external form)))))
    (nreverse specs)))

(defun consent--feature-requirement-satisfied-p
    (requirement context environment)
  "Return non-nil when cond-expand REQUIREMENT is satisfied."
  (cond
   ((consent--identifier-datum-p requirement)
    (equal (consent--symbol-name requirement) "r7rs"))
   ((consp requirement)
    (let* ((parts (consent--proper-list-elements
                   requirement "feature requirement"))
           (operator (car parts)))
      (cond
       ((consent--symbol-named-p operator "library")
        (unless (= (length parts) 2)
          (consent--eval-error
           "library feature requirement requires one library name"))
        (consent--library-available-p (cadr parts) context environment))
       ((consent--symbol-named-p operator "and")
        (cl-every
         (lambda (nested)
           (consent--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((consent--symbol-named-p operator "or")
        (cl-some
         (lambda (nested)
           (consent--feature-requirement-satisfied-p
            nested context environment))
         (cdr parts)))
       ((consent--symbol-named-p operator "not")
        (unless (= (length parts) 2)
          (consent--eval-error
           "not feature requirement requires one nested requirement"))
        (not
         (consent--feature-requirement-satisfied-p
          (cadr parts) context environment)))
       (t nil))))
   (t nil)))

(defun consent--expand-library-cond-expand
    (clauses context environment)
  "Return library declarations selected from cond-expand CLAUSES."
  (let ((selected nil)
        declarations)
    (dolist (clause clauses)
      (unless selected
        (let ((parts (consent--proper-list-elements
                      clause "cond-expand clause")))
          (when parts
            (let ((requirement (car parts)))
              (when (or (consent--symbol-named-p requirement "else")
                        (consent--feature-requirement-satisfied-p
                         requirement context environment))
                (setq selected t)
                (setq declarations (cdr parts))))))))
    (unless selected
      (consent--eval-error "unfulfilled library cond-expand"))
    declarations))

(defun consent--expand-library-declaration
    (declaration context environment)
  "Return DECLARATION after expanding library-level cond-expand."
  (cond
   ((consent--form-named-p declaration "cond-expand")
    (apply
     #'append
     (mapcar
      (lambda (nested)
        (consent--expand-library-declaration
         nested context environment))
      (consent--expand-library-cond-expand
       (cdr (consent--proper-list-elements
             declaration "library cond-expand"))
       context
       environment))))
   ((consent--form-named-p declaration "include-library-declarations")
    (consent--expand-include-library-declarations
     declaration context environment))
   (t
    (list declaration))))

(defun consent--include-filenames (declaration)
  "Return validated string filenames from include DECLARATION."
  (let* ((parts (consent--proper-list-elements
                 declaration "include declaration"))
         (operator-name (consent--symbol-name (car parts))))
    (unless (cdr parts)
      (consent--eval-error
       "%s requires at least one filename" operator-name))
    (mapcar
     (lambda (filename)
       (unless (stringp filename)
         (consent--eval-error
          "%s filename must be a string literal" operator-name))
       filename)
     (cdr parts))))

(defun consent--file-truename-or-expanded (path)
  "Return PATH's truename when possible, otherwise its expanded name."
  (if (file-exists-p path)
      (file-truename path)
    (expand-file-name path)))

(defun consent--path-policy-allows-file-p (path allowed-paths)
  "Return non-nil if ALLOWED-PATHS allow reading PATH."
  (let ((canonical-path
         (consent--file-truename-or-expanded path)))
    (cl-some
     (lambda (allowed)
       (let ((canonical-allowed
              (consent--file-truename-or-expanded allowed)))
         (or (equal canonical-path canonical-allowed)
             (and (file-directory-p canonical-allowed)
                  (file-in-directory-p canonical-path
                                       canonical-allowed)))))
     allowed-paths)))

(defun consent--include-policy-allows-file-p (path context)
  "Return non-nil if CONTEXT policy allows reading PATH."
  (consent--path-policy-allows-file-p
   path
   (consent--eval-context-include-paths context)))

(defun consent--resolve-include-file (filename context operation)
  "Return policy-checked absolute include path for FILENAME."
  (let* ((operation-symbol
          (pcase operation
            ("include" 'include)
            ("include-ci" 'include-ci)
            ("include-library-declarations" 'library-source)
            (_ (intern operation))))
         (authorization
          (consent-capability-authorize-file
           filename
           context
           operation-symbol
           operation
         (consent--eval-context-include-paths context)))
         (path (plist-get authorization :path)))
    (consent-capability-revalidate-file-authorization authorization)
    (unless (file-readable-p path)
      (consent-capability-audit-file-result
       authorization
       "include file is not readable"
       t)
      (consent--eval-error
       "include file is not readable: %s" filename))
    (consent-capability-audit-file-result authorization 'read)
    path))

(defun consent--with-include-directory (context directory thunk)
  "Call THUNK while CONTEXT resolves relative includes from DIRECTORY."
  (let ((previous-directory
         (consent--eval-context-include-directory context)))
    (unwind-protect
        (progn
          (setf (consent--eval-context-include-directory context)
                (file-name-as-directory directory))
          (funcall thunk))
      (setf (consent--eval-context-include-directory context)
            previous-directory))))

(defun consent--read-include-file-forms (filename context fold-case)
  "Read FILENAME into forms after include policy checks.
When FOLD-CASE is non-nil, read as if the file began with
`#!fold-case'.  The return value is (FORMS . DIRECTORY)."
  (let* ((path (consent--resolve-include-file
                filename context (if fold-case "include-ci" "include")))
         (source
          (with-temp-buffer
            (insert-file-contents path)
            (buffer-string)))
         (forms
          (consent-read-all
           (if fold-case
               (concat "#!fold-case\n" source)
             source))))
    (cons forms (file-name-directory path))))

(defun consent--library-include-body-forms
    (declaration context fold-case)
  "Return body forms read by include DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (car (consent--read-include-file-forms
            filename context fold-case)))
    (consent--include-filenames declaration))))

(defun consent--expand-include-library-declarations
    (declaration context environment)
  "Return declarations spliced from include-library-declarations DECLARATION."
  (apply
   #'append
   (mapcar
    (lambda (filename)
      (let* ((read-result
              (let ((path
                     (consent--resolve-include-file
                      filename context "include-library-declarations")))
                (let ((source
                       (with-temp-buffer
                         (insert-file-contents path)
                         (buffer-string))))
                  (cons (consent-read-all source)
                        (file-name-directory path)))))
             (forms (car read-result))
             (directory (cdr read-result)))
        (consent--with-include-directory
         context
         directory
         (lambda ()
           (apply
            #'append
            (mapcar
             (lambda (nested)
               (consent--expand-library-declaration
                nested context environment))
             forms))))))
    (consent--include-filenames declaration))))

(defun consent--library-export-binding
    (spec library-key value-environment syntax-environment)
  "Return the library binding described by export SPEC."
  (let* ((internal-name (car spec))
         (external-name (cdr spec))
         (cell
          (consent--environment-cell value-environment internal-name))
         (syntax-binding
          (consent--syntax-environment-ref
           syntax-environment internal-name)))
    (cond
     ((and cell syntax-binding)
      (consent--eval-error
       "export identifier has both value and syntax bindings: %s"
       internal-name))
     (cell
      (consent--make-library-binding
       external-name 'value cell library-key))
     (syntax-binding
      (consent--make-library-binding
       external-name 'syntax syntax-binding library-key))
     (t
      (consent--eval-error
       "exported identifier is not bound: %s" internal-name)))))

(defun consent--library-exports-from-specs
    (specs library-key value-environment syntax-environment)
  "Return export bindings for SPECS from library environments."
  (consent--ensure-distinct-names
   (mapcar #'cdr specs)
   "library exports")
  (consent--ensure-compatible-import-bindings
   (mapcar
    (lambda (spec)
      (consent--library-export-binding
       spec library-key value-environment syntax-environment))
    specs)))

(defun consent--eval-library-begin
    (forms value-environment syntax-environment context)
  "Evaluate library body FORMS in explicit library environments."
  (consent--with-syntax-environment
   context
   syntax-environment
   (lambda ()
     (consent--trampoline
      (consent--make-sequence forms t)
      value-environment
      context))))

(defun consent--eval-define-library (form environment context)
  "Evaluate a top-level R7RS define-library FORM."
  (let* ((parts (consent--proper-list-elements
                 form "define-library form"))
         (name (cadr parts)))
    (unless (>= (length parts) 2)
      (consent--eval-error
       "define-library requires a library name"))
    (unless (consent--library-name-p name)
      (consent--eval-error
       "invalid library name: %s" (consent-value->external name)))
    (let* ((library-key (consent--library-name-key name))
           (value-environment (consent-make-empty-environment))
           (syntax-environment
            (consent--make-empty-syntax-environment))
           export-specs)
      (dolist (raw-declaration (cddr parts))
        (dolist (declaration
                 (consent--expand-library-declaration
                  raw-declaration context environment))
          ;; `cond-expand' and include-library-declarations are flattened
          ;; before this dispatch so only core R7RS library declarations remain.
          (let* ((declaration-parts
                  (consent--proper-list-elements
                   declaration "library declaration"))
                 (operator (car declaration-parts)))
            (cond
             ((consent--symbol-named-p operator "export")
              (setq export-specs
                    (append export-specs
                            (consent--export-specs
                             (cdr declaration-parts)))))
             ((consent--symbol-named-p operator "import")
              (consent--with-syntax-environment
               context
               syntax-environment
               (lambda ()
                 (consent--eval-import
                  declaration value-environment context))))
             ((consent--symbol-named-p operator "begin")
              (consent--eval-library-begin
               (cdr declaration-parts)
               value-environment
               syntax-environment
               context))
             ((consent--symbol-named-p operator "include")
              (consent--eval-library-begin
               (consent--library-include-body-forms
                declaration context nil)
               value-environment
               syntax-environment
               context))
             ((consent--symbol-named-p operator "include-ci")
              (consent--eval-library-begin
               (consent--library-include-body-forms
                declaration context t)
               value-environment
               syntax-environment
               context))
             ((consent--symbol-named-p
               operator "include-library-declarations")
              (consent--eval-error
               "include-library-declarations must expand before evaluation"))
             (t
              (consent--eval-error
               "unsupported library declaration: %s"
               (consent-value->external declaration)))))))
      (puthash
       library-key
       (consent--make-library
        name
        library-key
        (consent--library-exports-from-specs
         export-specs library-key value-environment syntax-environment)
        value-environment
        syntax-environment)
       (consent--eval-context-libraries context))
      consent-unspecified)))


(provide 'consent-library)

;;; consent-library.el ends here
