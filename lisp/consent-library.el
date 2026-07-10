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
(require 'consent-policy)

(defconst consent--library-module-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing the loaded Consent Scheme library module.")

(defcustom consent-library-system-path
  (list (expand-file-name "../scheme/" consent--library-module-directory))
  "System manifest roots containing top-level `manifest.sld' files."
  :type '(repeat directory)
  :group 'consent)

(defcustom consent-library-user-path nil
  "User manifest roots containing top-level `manifest.sld' files."
  :type '(repeat directory)
  :group 'consent)

(defvar consent--source-library-environments (make-hash-table :test #'equal)
  "Private evaluator environments used for source-backed adapter calls.")

(defvar consent--source-library-procedures (make-hash-table :test #'equal)
  "Cached source-backed procedures keyed by library and procedure name.")

(defvar consent--source-library-internal-imports-allowed nil
  "Non-nil while loading trusted runtime source libraries.")

(defconst consent--source-library-lisp-eval-depth 32768
  "Minimum Lisp recursion depth while evaluating trusted source libraries.")

(defconst consent--source-library-call-options
  '(:max-steps 12000000
    :max-host-callbacks 2000000)
  "Evaluation budget for calls into cached source-backed libraries.")

(defvar consent--library-catalog-cache nil
  "Cached manifest-backed library catalog entries.")

(defvar consent--library-collection-manifest-cache nil
  "Cached metadata read from configured collection manifests.")

(defvar consent--library-catalog-ad-hoc-manifests nil
  "Ad-hoc manifest catalog sources, as (SOURCE-ID . ENTRIES).")

(defvar consent--library-catalog-root-manifests nil
  "Explicit manifest-root catalog sources, as (ROOT . ENTRIES).")

(defvar consent--library-catalog-diagnostics nil
  "Diagnostics from the most recent manifest-backed catalog build.")

(defvar consent--primitive-library-provider-declarations nil
  "Provider-contributed primitive-library declarations.")

(declare-function consent--apply-procedure "consent-interpreter")
(declare-function consent--make-empty-syntax-environment "consent-macro")
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
  "manifest.sld"
  "Seed-root top-level Scheme manifest index source file.")

(defun consent--manifest-source-library-form
    (key source-file description &optional root)
  "Return the single define-library form for KEY from manifest SOURCE-FILE."
  (let ((forms
         (consent-read-all
          (consent--manifest-source-library-source
           source-file
           key
           root))))
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
            (root (plist-get manifest-entry :root))
            (form (consent--manifest-source-library-form
                   key
                   source-file
                   "standard source library"
                   root)))
       (list :name key
             :exports
             (consent--source-library-export-names form)
             :source-file
             (consent--manifest-source-library-file source-file root))))
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

(defun consent--library-normalize-root-directory (directory)
  "Return DIRECTORY as an absolute directory name."
  (file-name-as-directory (expand-file-name directory)))

(defun consent--library-manifest-root-file (root relative-file)
  "Return absolute path for root-relative RELATIVE-FILE under ROOT."
  (expand-file-name relative-file root))

(defun consent--library-manifest-root-descriptors ()
  "Return configured manifest root descriptors in initial precedence order."
  (let (roots)
    (dolist (entry `((system . ,consent-library-system-path)
                     (user . ,consent-library-user-path)))
      (let ((kind (car entry)))
        (dolist (directory (cdr entry))
          (let* ((root (consent--library-normalize-root-directory
                        directory))
                 (manifest
                  (consent--library-manifest-root-file
                   root
                   consent--library-manifest-index-file)))
            (when (file-readable-p manifest)
              (push (list :root root :root-kind kind) roots))))))
    (nreverse roots)))

(defun consent--library-default-manifest-root ()
  "Return the first configured manifest root, or signal an error."
  (or (plist-get (car (consent--library-manifest-root-descriptors)) :root)
      (consent--eval-error
       "no configured manifest root contains %s"
       consent--library-manifest-index-file)))

(defun consent--library-read-file (source-file description)
  "Return SOURCE-FILE contents, or signal DESCRIPTION."
  (unless (file-readable-p source-file)
    (consent--eval-error "%s is not readable: %s" description source-file))
  (with-temp-buffer
    (insert-file-contents source-file)
    (buffer-string)))

(defun consent--library-manifest-index-source (root)
  "Return ROOT's top-level Scheme manifest index source."
  (consent--library-read-file
   (consent--library-manifest-root-file
    root
    consent--library-manifest-index-file)
   "top-level manifest index file"))

(defun consent--collection-manifest-source (spec)
  "Return source text for collection manifest described by SPEC."
  (consent--library-read-file
   (consent--library-manifest-root-file
    (plist-get spec :root)
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
  (let* ((max-lisp-eval-depth
          (max max-lisp-eval-depth consent--source-library-lisp-eval-depth))
         (forms (consent-read-all source '(:source-metadata nil))))
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

(defun consent--library-manifest-index-value (root)
  "Return ROOT's quoted top-level manifest index."
  (consent--manifest-library-quoted-variable
   (consent--library-manifest-index-source root)
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

(defun consent--collection-manifest-fields (entry description)
  "Return tagged manifest ENTRY fields, or signal DESCRIPTION."
  (let ((parts (consent--proper-list-elements entry description)))
    (unless (and parts
                 (or (consent--symbol-named-p (car parts) "manifest-entry")
                     (consent--symbol-named-p
                      (car parts)
                      "manifest-index-entry")))
      (consent--eval-error
       "%s must begin with manifest-entry or manifest-index-entry"
       description))
    (cdr parts)))

(defun consent--collection-manifest-field (entry name &optional default)
  "Return NAME from tagged manifest ENTRY, or DEFAULT when absent."
  (let ((cell
         (seq-find
          (lambda (field)
            (let ((parts
                   (and (consp field)
                        (consent--proper-list-elements-maybe field))))
              (and parts
                   (consent--symbol-named-p (car parts) name))))
          (consent--collection-manifest-fields entry "manifest entry"))))
    (if cell
        (let ((parts (consent--proper-list-elements cell "manifest field")))
          (if (cdr parts) (cadr parts) default))
      default)))

(defun consent--collection-manifest-field-values (entry name)
  "Return all values for NAME from tagged manifest ENTRY."
  (let ((cell
         (seq-find
          (lambda (field)
            (let ((parts
                   (and (consp field)
                        (consent--proper-list-elements-maybe field))))
              (and parts
                   (consent--symbol-named-p (car parts) name))))
          (consent--collection-manifest-fields entry "manifest entry"))))
    (if cell
        (cdr (consent--proper-list-elements cell "manifest field"))
      nil)))

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

(defun consent--collection-manifest-index-entry (root-descriptor entry)
  "Return a collection manifest descriptor parsed from index ENTRY."
  (let* ((collection
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "collection" nil)
           "manifest index collection"))
         (root (plist-get root-descriptor :root))
         (root-kind (plist-get root-descriptor :root-kind))
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
          :root root
          :root-kind root-kind
          :category category
          :source-root source-root
          :source-id (format "%s:%s" root collection))))

(defun consent--library-collection-manifest-specs ()
  "Return collection manifest descriptors from configured manifest roots."
  (apply
   #'append
   (mapcar
    (lambda (root-descriptor)
      (mapcar
       (lambda (entry)
         (consent--collection-manifest-index-entry root-descriptor entry))
       (consent--proper-list-elements
        (consent--library-manifest-index-value
         (plist-get root-descriptor :root))
        "top-level manifest index entries")))
    (consent--library-manifest-root-descriptors))))

(defun consent--library-manifest-root-cache-key ()
  "Return cache key for configured manifest root lists."
  (list (mapcar #'consent--library-normalize-root-directory
                consent-library-system-path)
        (mapcar #'consent--library-normalize-root-directory
                consent-library-user-path)))

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

(defun consent--primitive-library-export-field (entry field description)
  "Return FIELD from primitive export ENTRY, or signal DESCRIPTION."
  (let ((sentinel (list 'primitive-field-absent)))
    (let ((value (catch 'field
                   (dolist (candidate
                            (consent--proper-list-elements entry description))
                     (let ((parts
                            (and (consp candidate)
                                 (consent--proper-list-elements
                                  candidate description))))
                       (when (and parts
                                  (consent--symbol-named-p (car parts) field))
                         (unless (cdr parts)
                           (consent--eval-error
                            "%s field %s must have a value"
                            description field))
                         (throw 'field
                                (if (cddr parts) (cdr parts) (cadr parts))))))
                   sentinel)))
      (if (eq value sentinel)
          (consent--eval-error "%s missing field: %s" description field)
        value))))

(defun consent--primitive-library-symbol-list (value description)
  "Return VALUE as a list of symbols for primitive export DESCRIPTION."
  (mapcar
   (lambda (entry)
     (consent--collection-manifest-symbol entry description))
   (consent--proper-list-elements value description)))

(defun consent--primitive-library-arity (value description)
  "Return primitive arity VALUE as (MINIMUM MAXIMUM)."
  (let ((parts (consent--proper-list-elements value description)))
    (unless (= (length parts) 2)
      (consent--eval-error "%s must have minimum and maximum" description))
    (let ((minimum
           (consent--manifest-nonnegative-integer
            (car parts) (format "%s minimum" description)))
          (maximum
           (if (eq (cadr parts) consent-false)
               nil
             (consent--manifest-nonnegative-integer
              (cadr parts) (format "%s maximum" description)))))
      (unless minimum
        (consent--eval-error "%s minimum is required" description))
      (when (and maximum (> minimum maximum))
        (consent--eval-error
         "%s maximum must be greater than or equal to minimum"
         description))
      (list minimum maximum))))

(defun consent--primitive-library-normalize-export (entry description)
  "Return normalized primitive export ENTRY for DESCRIPTION."
  (let* ((name
          (consent--expect-symbol-name
           (consent--primitive-library-export-field entry "name" description)
           (format "%s name" description)))
         (primitive
          (consent--collection-manifest-symbol
           (consent--primitive-library-export-field
            entry "primitive" description)
           (format "%s primitive" description)))
         (arity
          (consent--primitive-library-arity
           (consent--primitive-library-export-field
            entry "arity" description)
           (format "%s arity" description)))
         (effects
          (consent--primitive-library-symbol-list
           (consent--primitive-library-export-field
            entry "effects" description)
           (format "%s effects" description)))
         (capabilities
          (consent--primitive-library-symbol-list
           (consent--primitive-library-export-field
            entry "capabilities" description)
           (format "%s capabilities" description))))
    (list :name name
          :primitive primitive
          :arity arity
          :effects effects
          :capabilities capabilities)))

(defun consent--primitive-library-normalize-exports (value description)
  "Return primitive export declarations from VALUE for DESCRIPTION."
  (if (or (null value) (eq value consent-false))
      nil
    (mapcar
     (lambda (entry)
       (consent--primitive-library-normalize-export entry description))
     (consent--proper-list-elements value description))))

(defconst consent--manifest-schema-version 1
  "Current shared manifest schema version.")

(defun consent--manifest-nonnegative-integer (value description &optional default)
  "Return VALUE as an exact non-negative integer, or DEFAULT when absent."
  (cond
   ((or (null value) (eq value consent-false)) default)
   ((and (integerp value) (>= value 0)) value)
   ((let ((integer (and (fboundp 'consent--exact-integer-value)
                        (consent--exact-integer-value value))))
      (and integer (>= integer 0) integer)))
   (t
    (consent--eval-error
     "%s must be an exact non-negative integer" description))))

(defun consent--manifest-boolean (value description &optional default)
  "Return VALUE as a boolean, or DEFAULT when absent."
  (cond
   ((null value) default)
   ((eq value consent-false) nil)
   ((eq value t) t)
   ((consent-boolean-p value) (consent-boolean-value value))
   (t (consent--eval-error "%s must be a boolean" description))))

(defun consent--manifest-symbol-datum (symbol)
  "Return SYMBOL as a Consent Scheme symbol datum."
  (consent--syntax-symbol (symbol-name symbol)))

(defun consent--manifest-kind-default (source-kind target)
  "Return default manifest kind for SOURCE-KIND and TARGET."
  (cond
   ((or target (eq source-kind 'alias)) 'library-alias)
   ((eq source-kind 'primitive) 'primitive-library)
   (t 'library)))

(defun consent--manifest-api-version-default (visibility target)
  "Return default api-version metadata for VISIBILITY and TARGET."
  (cond
   (target
    (consent-read (format "(inherits %s)" target)))
   ((memq visibility '(internal-runtime internal-agent-primitive host-adapter))
    'internal)
   (t
    (consent-read "(compat 0)"))))

(defun consent--manifest-source-version-default (source-kind)
  "Return default source-version metadata for SOURCE-KIND."
  (if (memq source-kind '(base-snapshot primitive derived))
      'runtime
    'unknown))

(defun consent--manifest-realization-default (source-kind)
  "Return default realization metadata for SOURCE-KIND."
  (pcase source-kind
    ('portable-source 'portable-source)
    ('primitive 'host-primitive)
    ('alias 'alias)
    ('base-snapshot 'runtime-snapshot)
    ('derived 'derived)
    ('facade 'shim)
    (_ (or source-kind 'unknown))))

(defun consent--manifest-source-path (source)
  "Return path from manifest SOURCE metadata, or nil."
  (when (consp source)
    (let ((parts (consent--proper-list-elements source "manifest source")))
      (when (and (= (length parts) 2)
                 (consent--symbol-named-p (car parts) "path")
                 (stringp (cadr parts)))
        (cadr parts)))))

(defun consent--manifest-source-implementation-id (source)
  "Return implementation id from manifest SOURCE metadata, or nil."
  (when (consp source)
    (let ((parts (consent--proper-list-elements source "manifest source")))
      (when (and (= (length parts) 2)
                 (consent--symbol-named-p (car parts) "implementation-id"))
        (consent--collection-manifest-symbol
         (cadr parts)
         "manifest source implementation-id")))))

(defun consent--manifest-source-with-path (source path)
  "Return SOURCE normalized to resolved PATH when SOURCE is a path datum."
  (if (and path (consp source))
      (let ((parts (consent--proper-list-elements source "manifest source")))
        (if (and (= (length parts) 2)
                 (consent--symbol-named-p (car parts) "path"))
            (list (consent--manifest-symbol-datum 'path) path)
          source))
    source))

(defun consent--manifest-source-default (source source-file target implementation-id)
  "Return normalized source metadata.
Use SOURCE-FILE, TARGET, or IMPLEMENTATION-ID when SOURCE is absent."
  (cond
   ((and source (not (eq source consent-false))) source)
   (source-file
    (list (consent--manifest-symbol-datum 'path) source-file))
   (target
    (list (consent--manifest-symbol-datum 'target)
          (consent-read target)))
   (implementation-id
    (list (consent--manifest-symbol-datum 'implementation-id)
          (consent--manifest-symbol-datum implementation-id)))
   (t (consent--manifest-symbol-datum 'unknown))))

(defun consent--manifest-documentation-summary (documentation)
  "Return summary text from DOCUMENTATION metadata, or nil."
  (catch 'summary
    (dolist (entry (and (consp documentation)
                        (consent--proper-list-elements
                         documentation
                         "manifest documentation")))
      (when (consp entry)
        (let ((parts (consent--proper-list-elements
                      entry
                      "manifest documentation entry")))
          (when (and (= (length parts) 2)
                     (consent--symbol-named-p (car parts) "summary")
                     (stringp (cadr parts)))
            (throw 'summary (cadr parts))))))
    nil))

(defun consent--manifest-documentation-default (documentation summary)
  "Return DOCUMENTATION or summary-derived documentation metadata."
  (cond
   ((and documentation (not (eq documentation consent-false))) documentation)
   (summary
    (list (list (consent--manifest-symbol-datum 'summary) summary)))
   (t nil)))

(defun consent--manifest-provenance-default (provenance origin source-id)
  "Return PROVENANCE or a minimal origin/source-id record."
  (if (and provenance (not (eq provenance consent-false)))
      provenance
    (delq nil
          (list
           (list (consent--manifest-symbol-datum 'origin)
                 (consent--manifest-symbol-datum origin))
           (and source-id
                (list (consent--manifest-symbol-datum 'source-id)
                      (if (symbolp source-id)
                          (consent--manifest-symbol-datum source-id)
                        source-id)))))))

(defun consent--manifest-normalized-dependency (entry)
  "Return dependency ENTRY as a normalized library key."
  (let ((parts (and (consp entry)
                    (consent--proper-list-elements-maybe entry))))
    (if (and parts
             (consent--symbol-named-p (car parts) "library")
             (cadr parts))
        (consent--library-name-key (cadr parts))
      (consent--library-name-key entry))))

(defun consent--manifest-library-list (value description)
  "Return VALUE normalized as a list of dependency library-name keys."
  (if (or (null value) (eq value consent-false))
      nil
    (mapcar
     (lambda (entry)
       (consent--manifest-normalized-dependency entry))
     (consent--proper-list-elements value description))))

(defun consent--collection-manifest-default-visibility (status)
  "Return the default visibility implied by manifest STATUS."
  (if (eq status 'alias) 'alias 'public))

(defun consent--collection-manifest-entry (entry spec)
  "Return catalog metadata parsed from collection manifest ENTRY and SPEC."
  (let* ((key
          (consent--library-name-key
           (consent--collection-manifest-field entry "name" nil)))
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
         (schema-version
          (consent--manifest-nonnegative-integer
           (consent--collection-manifest-field entry "schema-version" nil)
           "collection manifest schema-version"
           consent--manifest-schema-version))
         (kind
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "kind" nil)
           "collection manifest kind"
           (consent--manifest-kind-default source-kind target)))
         (source
          (consent--collection-manifest-field entry "source" nil))
         (implementation-id
          (consent--manifest-source-implementation-id source))
         (primitive-overlay-library
          (consent--collection-manifest-target
           (consent--collection-manifest-field
            entry "primitive-overlay-library" nil)))
         (implementation-resolver
          (consent--collection-manifest-field-values
           entry "implementation-resolver"))
         (primitive-exports
          (consent--primitive-library-normalize-exports
           (consent--collection-manifest-field-values
            entry "primitive-exports")
           "collection manifest primitive-exports"))
         (exports-absent (list 'exports-absent))
         (source-file
          (consent--manifest-source-path source))
         (dependencies
          (consent--manifest-library-list
           (consent--collection-manifest-field entry "dependencies" nil)
           "collection manifest dependencies"))
         (aliases
          (consent--manifest-library-list
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
          (consent--collection-manifest-field entry "summary" nil))
         (owner
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "owner" nil)
           "collection manifest owner"
           (plist-get spec :category)))
         (provider
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "provider" nil)
           "collection manifest provider"
           'repo-source))
         (api-version
          (consent--manifest-metadata-value
           (consent--collection-manifest-field entry "api-version" nil)))
         (source-version
          (consent--manifest-metadata-value
           (consent--collection-manifest-field entry "source-version" nil)))
         (realization
          (consent--collection-manifest-symbol
           (consent--collection-manifest-field entry "realization" nil)
           "collection manifest realization"
           nil))
         (effects
          (consent--collection-manifest-field entry "effects" nil))
         (capabilities
          (consent--collection-manifest-field entry "capabilities" nil))
         (documentation
          (consent--collection-manifest-field entry "documentation" nil))
         (provenance
          (consent--collection-manifest-field entry "provenance" nil))
         (canonical
          (consent--manifest-boolean
           (consent--collection-manifest-field entry "canonical" nil)
           "collection manifest canonical"
           (not (and target (eq source-kind 'alias))))))
    (when (eq source-file consent-false)
      (setq source-file nil))
    (unless (or (null source-file) (stringp source-file))
      (consent--eval-error
       "collection manifest source-file must be a string or #f"))
    (setq source-file
          (consent--collection-manifest-catalog-source-file
           spec source-kind source-file))
    (setq source
          (consent--manifest-source-with-path source source-file))
    (unless (= schema-version consent--manifest-schema-version)
      (consent--eval-error
       "unsupported collection manifest schema-version: %s"
       schema-version))
    (when (eq exports exports-absent)
      (if (and target (eq source-kind 'alias))
          (setq exports nil)
        (consent--eval-error
         "built-in manifest entry must declare exports: %s"
         key)))
    (when (eq summary consent-false)
      (setq summary nil))
    (unless (or (null summary) (stringp summary))
      (consent--eval-error
       "collection manifest summary must be a string or #f"))
    (setq documentation
          (consent--manifest-documentation-default documentation summary))
    (unless summary
      (setq summary
            (consent--manifest-documentation-summary documentation)))
    (unless api-version
      (setq api-version
            (consent--manifest-api-version-default visibility target)))
    (unless source-version
      (setq source-version
            (consent--manifest-source-version-default source-kind)))
    (unless realization
      (setq realization
            (consent--manifest-realization-default source-kind)))
    (setq source
          (consent--manifest-source-default
           source source-file target implementation-id))
    (setq provenance
          (consent--manifest-provenance-default
           provenance 'repo (plist-get spec :source-id)))
    (list :name key
          :schema-version schema-version
          :kind kind
          :category category
          :status status
          :source-kind source-kind
          :implementation-id implementation-id
          :primitive-overlay-library primitive-overlay-library
          :implementation-resolver implementation-resolver
          :primitive-exports primitive-exports
          :visibility visibility
          :layer layer
          :owner owner
          :provider provider
          :availability availability
          :availability-condition availability-condition
          :api-version api-version
          :source-version source-version
          :realization realization
          :source source
          :root (plist-get spec :root)
          :root-kind (plist-get spec :root-kind)
          :source-file source-file
          :aliases aliases
          :target target
          :exports exports
          :dependencies dependencies
          :effects effects
          :capabilities capabilities
          :documentation documentation
          :provenance provenance
          :canonical canonical
          :origin 'built-in-seed
          :source-id (plist-get spec :source-id)
          :summary summary)))

(defun consent--library-collection-manifest-entries ()
  "Return collection-manifest metadata for configured manifest roots."
  (let ((cache-key (consent--library-manifest-root-cache-key)))
    (if (and consent--library-collection-manifest-cache
             (equal (car consent--library-collection-manifest-cache)
                    cache-key))
        (cadr consent--library-collection-manifest-cache)
      (cadr
       (setq
        consent--library-collection-manifest-cache
        (list
         cache-key
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
           (consent--library-collection-manifest-specs)))))))))

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
  (memq visibility
        '(internal-runtime internal-agent-primitive internal-agent-model)))

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

(defun consent--ensure-library-import-allowed (key context &optional entry)
  "Signal when KEY is not importable in CONTEXT's current posture."
  (let ((visibility (or (plist-get entry :visibility)
                        (consent--library-visibility key))))
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

(defun consent--library-catalog-manifest-field-values (fields name)
  "Return every value for NAME from manifest FIELDS."
  (let ((field (consent--library-catalog-field-form fields name)))
    (and field (cdr field))))

(defun consent--library-catalog-require-symbol (value description)
  "Return VALUE as an Emacs Lisp symbol, or signal DESCRIPTION."
  (cond
   ((symbolp value) value)
   ((consent-symbol-p value) (intern (consent-symbol-name value)))
   (t (consent--eval-error "%s must be a symbol" description))))

(defun consent--library-catalog-optional-symbol (value description)
  "Return VALUE as an Emacs Lisp symbol, or nil when absent."
  (unless (or (null value) (eq value consent-false))
    (consent--library-catalog-require-symbol value description)))

(defun consent--manifest-metadata-value (value)
  "Return VALUE with plain Consent symbols normalized for catalog metadata."
  (if (consent-symbol-p value)
      (intern (consent-symbol-name value))
    value))

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
  (consent--manifest-library-list value description))

(defun consent--library-catalog-require-target (value)
  "Return VALUE as a normalized library-name key, or nil."
  (unless (or (null value) (eq value consent-false))
    (consent--library-name-key value)))

(defun consent--library-catalog-normalized-source-kind (value target)
  "Return catalog SOURCE-KIND from manifest VALUE and TARGET."
  (or (consent--collection-manifest-source-kind value)
      (and target 'alias)
      'manifest))

(defun consent--library-catalog-manifest-library (form origin source-id)
  "Validate manifest library FORM under ORIGIN and SOURCE-ID."
  (let ((parts (consent--proper-list-elements form "catalog library entry")))
    (unless (and parts
                 (or (consent--symbol-named-p (car parts) "manifest-entry")
                     (consent--symbol-named-p
                      (car parts)
                      "manifest-index-entry")))
      (consent--eval-error
       "catalog entry must begin with manifest-entry or manifest-index-entry"))
    (let* ((fields (cdr parts))
           (index-entry
            (consent--symbol-named-p (car parts) "manifest-index-entry"))
           (name
            (consent--library-name-key
             (consent--library-catalog-manifest-field fields "name" nil)))
           (status
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "status" 'available)
             "catalog status"))
           (visibility
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "visibility" 'public)
             "catalog visibility"))
           (aliases
            (consent--library-catalog-require-library-list
             (consent--library-catalog-manifest-field fields "aliases" nil)
             "catalog aliases"))
           (target
            (consent--library-catalog-require-target
             (consent--library-catalog-manifest-field fields "target" nil)))
           (source-kind
            (consent--library-catalog-normalized-source-kind
             (consent--library-catalog-manifest-field
              fields "source-kind" nil)
             target))
           (availability
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "availability" 'required)
             "catalog availability"))
           (availability-condition
            (consent--library-catalog-manifest-field
             fields "availability-condition" nil))
           (schema-version
            (consent--manifest-nonnegative-integer
             (consent--library-catalog-manifest-field
              fields "schema-version" nil)
             "catalog schema-version"
             consent--manifest-schema-version))
           (kind
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields
              "kind"
              (consent--manifest-kind-default source-kind target))
             "catalog kind"))
           (category
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "category" (if index-entry 'alias 'library))
             "catalog category"))
           (source
            (consent--library-catalog-manifest-field fields "source" nil))
           (implementation-id
            (consent--manifest-source-implementation-id source))
           (primitive-overlay-library
            (consent--library-catalog-require-target
             (consent--library-catalog-manifest-field
              fields "primitive-overlay-library" nil)))
           (implementation-resolver
            (consent--library-catalog-manifest-field-values
             fields "implementation-resolver"))
           (primitive-exports
            (consent--primitive-library-normalize-exports
             (consent--library-catalog-manifest-field-values
              fields "primitive-exports")
             "catalog primitive-exports"))
           (source-file
            (consent--manifest-source-path source))
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
            (consent--library-catalog-manifest-field fields "summary" nil))
           (owner
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field fields "owner" 'project)
             "catalog owner"))
           (provider
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields "provider" origin)
             "catalog provider"))
           (layer
            (consent--library-catalog-optional-symbol
             (consent--library-catalog-manifest-field fields "layer" nil)
             "catalog layer"))
           (api-version
            (consent--manifest-metadata-value
             (consent--library-catalog-manifest-field
              fields "api-version" nil)))
           (source-version
            (consent--manifest-metadata-value
             (consent--library-catalog-manifest-field
              fields "source-version" nil)))
           (realization
            (consent--library-catalog-require-symbol
             (consent--library-catalog-manifest-field
              fields
              "realization"
              (consent--manifest-realization-default source-kind))
             "catalog realization"))
           (effects
            (consent--library-catalog-manifest-field fields "effects" nil))
           (capabilities
            (consent--library-catalog-manifest-field
             fields "capabilities" nil))
           (documentation
            (consent--library-catalog-manifest-field
             fields "documentation" nil))
           (provenance
            (consent--library-catalog-manifest-field
             fields "provenance" nil))
           (canonical
            (consent--manifest-boolean
             (consent--library-catalog-manifest-field fields "canonical" nil)
             "catalog canonical"
             (not (and target (eq source-kind 'alias))))))
      (unless (= schema-version consent--manifest-schema-version)
        (consent--eval-error
         "unsupported catalog schema-version: %s" schema-version))
      (when (eq summary consent-false)
        (setq summary nil))
      (unless (or (null summary) (stringp summary))
        (consent--eval-error "catalog summary must be a string or #f"))
      (setq documentation
            (consent--manifest-documentation-default documentation summary))
      (unless summary
        (setq summary
              (consent--manifest-documentation-summary documentation)))
      (unless api-version
        (setq api-version
              (consent--manifest-api-version-default visibility target)))
      (unless source-version
        (setq source-version
              (consent--manifest-source-version-default source-kind)))
      (setq source
            (consent--manifest-source-with-path source source-file))
      (setq source
            (consent--manifest-source-default
             source source-file target implementation-id))
      (setq provenance
            (consent--manifest-provenance-default
             provenance origin source-id))
      (list :name name
            :schema-version schema-version
            :kind kind
            :category category
            :status status
            :source-kind source-kind
            :implementation-id implementation-id
            :primitive-overlay-library primitive-overlay-library
            :implementation-resolver implementation-resolver
            :primitive-exports primitive-exports
            :visibility visibility
            :owner owner
            :provider provider
            :layer layer
            :availability availability
            :availability-condition availability-condition
            :api-version api-version
            :source-version source-version
            :realization realization
            :source source
            :source-file source-file
            :aliases aliases
            :target target
            :exports exports
            :dependencies dependencies
            :effects effects
            :capabilities capabilities
            :documentation documentation
            :provenance provenance
            :canonical canonical
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
  (let* ((root-directory
          (and (file-directory-p root)
               (consent--library-normalize-root-directory root)))
         (entries
          (mapcar
           (lambda (entry)
             (append entry
                     (delq nil
                           (list (and root-directory :root)
                                 root-directory
                                 :root-kind 'manifest-root))))
           (consent--library-catalog-parse-manifest
            manifest 'manifest-root root))))
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
     :schema-version (plist-get manifest-entry :schema-version)
     :kind (plist-get manifest-entry :kind)
     :category (or (plist-get manifest-entry :category)
                   (consent--library-catalog-category key))
     :status (or (plist-get manifest-entry :status)
                 'implemented)
     :source-kind source-kind
     :implementation-id (plist-get manifest-entry :implementation-id)
     :primitive-overlay-library
     (plist-get manifest-entry :primitive-overlay-library)
     :implementation-resolver
     (plist-get manifest-entry :implementation-resolver)
     :primitive-exports (plist-get manifest-entry :primitive-exports)
     :visibility (or (plist-get manifest-entry :visibility) 'public)
     :layer (plist-get manifest-entry :layer)
     :owner (plist-get manifest-entry :owner)
     :provider (plist-get manifest-entry :provider)
     :availability (or (plist-get manifest-entry :availability) 'required)
     :availability-condition
     (plist-get manifest-entry :availability-condition)
     :api-version (plist-get manifest-entry :api-version)
     :source-version (plist-get manifest-entry :source-version)
     :realization (plist-get manifest-entry :realization)
     :source (plist-get manifest-entry :source)
     :root (plist-get manifest-entry :root)
     :root-kind (plist-get manifest-entry :root-kind)
     :source-file source-file
     :aliases (if (plist-member manifest-entry :aliases)
                  (plist-get manifest-entry :aliases)
                (consent--library-catalog-aliases key))
     :target (plist-get manifest-entry :target)
     :exports (consent--library-catalog-export-names key)
     :dependencies (consent--library-catalog-dependencies key)
     :effects (plist-get manifest-entry :effects)
     :capabilities (plist-get manifest-entry :capabilities)
     :documentation (plist-get manifest-entry :documentation)
     :provenance (plist-get manifest-entry :provenance)
     :canonical (plist-get manifest-entry :canonical)
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
  (let ((cache-key (consent--library-manifest-root-cache-key)))
    (if (and consent--library-catalog-cache
             (equal (car consent--library-catalog-cache) cache-key))
        (cadr consent--library-catalog-cache)
      (let ((entries
             (consent--library-catalog-deduplicate
              (consent--library-catalog-candidate-entries))))
        (setq consent--library-catalog-cache
              (list cache-key entries))
        entries))))

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
  (consent--library-catalog-entries)
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

(defun consent--library-catalog-candidates (library-name)
  "Return all catalog candidates for LIBRARY-NAME in precedence order."
  (let ((key (if (stringp library-name)
                 library-name
               (consent--library-name-key library-name))))
    (seq-filter
     (lambda (entry)
       (equal (plist-get entry :name) key))
     (consent--library-catalog-candidate-entries))))

(defun consent--library-record-symbol (symbol)
  "Return SYMBOL as a Scheme-readable symbol."
  (consent--syntax-symbol (symbol-name symbol)))

(defun consent--library-record-field (name value)
  "Return a Scheme-readable library resolver field."
  (list (consent--syntax-symbol name) value))

(defun consent--library-record-library-name (key)
  "Return library KEY as a Scheme-readable library-name datum."
  (if key
      (consent-read key)
    consent-false))

(defun consent--library-record-symbol-or-false (value)
  "Return symbol VALUE as a datum, or #f when absent."
  (if value
      (consent--library-record-symbol value)
    consent-false))

(defun consent--library-record-source-id (source-id)
  "Return SOURCE-ID as a Scheme-readable value."
  (cond
   ((stringp source-id) source-id)
   ((symbolp source-id) (consent--library-record-symbol source-id))
   ((consent-symbol-p source-id) source-id)
   ((null source-id) consent-false)
   (t source-id)))

(defun consent--library-record-root (entry)
  "Return ENTRY's root category."
  (let ((origin (plist-get entry :origin))
        (root-kind (plist-get entry :root-kind))
        (source-kind (plist-get entry :source-kind))
        (category (plist-get entry :category))
        (owner (plist-get entry :owner))
        (name (plist-get entry :name)))
    (cond
     ((eq origin 'ad-hoc-manifest) 'ad-hoc-manifest)
     ((eq origin 'manifest-root) 'manifest-root)
     ((eq root-kind 'user) 'user)
     ((eq source-kind 'base-snapshot) 'builtin)
     ((or (eq category 'standard)
          (eq category 'stdlib)
          (eq owner 'stdlib)
          (and (stringp name)
               (or (string-prefix-p "(srfi " name)
                   (string-prefix-p "(stdlib " name))))
      'stdlib-vendored)
     ((eq source-kind 'primitive) 'host-adapter)
     ((eq root-kind 'system) 'builtin)
     (t 'builtin))))

(defun consent--library-record-trust (root)
  "Return trust label for resolver ROOT."
  (pcase root
    ('ad-hoc-manifest 'ad-hoc)
    ('manifest-root 'explicit)
    ('user 'user)
    ('host-adapter 'host)
    ((or 'stdlib-vendored 'builtin) 'bundled)
    (_ 'unknown)))

(defun consent--library-entry-resolved-name (entry &optional seen)
  "Return ENTRY's final target key after alias expansion."
  (let ((key (plist-get entry :name))
        (target (plist-get entry :target)))
    (if (or (null target) (member key seen))
        key
      (let ((target-entry (consent--library-catalog-lookup target)))
        (if target-entry
            (consent--library-entry-resolved-name
             target-entry
             (cons key seen))
          target)))))

(defun consent--library-candidate-record (entry)
  "Return ENTRY as a Scheme-readable library-candidate record."
  (let* ((root (consent--library-record-root entry))
         (trust (consent--library-record-trust root)))
    (list
     (consent--syntax-symbol "library-candidate")
     (consent--library-record-field
      "name"
      (consent--library-record-library-name (plist-get entry :name)))
     (consent--library-record-field
      "root"
      (consent--library-record-symbol root))
     (consent--library-record-field
      "source-id"
      (consent--library-record-source-id (plist-get entry :source-id)))
     (consent--library-record-field
      "source-kind"
      (consent--library-record-symbol
       (or (plist-get entry :source-kind) 'manifest)))
     (consent--library-record-field
      "provider"
      (consent--library-record-symbol-or-false
       (plist-get entry :provider)))
     (consent--library-record-field
      "trust"
      (consent--library-record-symbol trust)))))

(cl-defun consent--library-resolution-record
    (name &key entry status reason loaded candidates)
  "Return a Scheme-readable resolution record for NAME."
  (let* ((key (if (stringp name) name (consent--library-name-key name)))
         (resolved-key (and entry (consent--library-entry-resolved-name entry)))
         (root (and entry (consent--library-record-root entry)))
         (trust (and root (consent--library-record-trust root)))
         (availability-condition
          (and entry (plist-get entry :availability-condition))))
    (append
     (list
      (consent--syntax-symbol "library-resolution")
      (consent--library-record-field
       "name"
       (consent--library-record-library-name key))
      (consent--library-record-field
       "resolved-name"
       (consent--library-record-library-name (or resolved-key key)))
      (consent--library-record-field
       "root"
       (consent--library-record-symbol-or-false root))
      (consent--library-record-field
       "source-kind"
       (consent--library-record-symbol-or-false
        (and entry (plist-get entry :source-kind))))
      (consent--library-record-field
       "source"
       (or (and entry (plist-get entry :source)) consent-false))
      (consent--library-record-field
       "source-file"
       (or (and entry (plist-get entry :source-file)) consent-false))
      (consent--library-record-field
       "visibility"
       (consent--library-record-symbol-or-false
        (and entry (plist-get entry :visibility))))
      (consent--library-record-field
       "layer"
       (consent--library-record-symbol-or-false
        (and entry (plist-get entry :layer))))
      (consent--library-record-field
       "owner"
       (consent--library-record-symbol-or-false
        (and entry (plist-get entry :owner))))
      (consent--library-record-field
       "provider"
       (consent--library-record-symbol-or-false
        (and entry (plist-get entry :provider))))
      (consent--library-record-field
       "trust"
       (consent--library-record-symbol-or-false trust))
      (consent--library-record-field
       "target"
       (consent--library-record-library-name
        (and entry (plist-get entry :target))))
      (consent--library-record-field
       "availability"
       (consent--library-record-symbol-or-false
        (and entry (plist-get entry :availability))))
      (consent--library-record-field
       "availability-condition"
       (or availability-condition consent-false))
      (consent--library-record-field
       "status"
       (consent--library-record-symbol status)))
     (delq
      nil
      (list
       (and reason
            (consent--library-record-field
             "reason"
             (consent--library-record-symbol reason)))
       (and loaded
            (consent--library-record-field
             "loaded?"
             consent-true))
       (and candidates
            (consent--library-record-field
             "candidates"
             (mapcar #'consent--library-candidate-record
                     candidates))))))))

(defun consent--library-resolve-record (name context)
  "Return NAME's deterministic library-resolution record in CONTEXT."
  (let* ((key (if (stringp name) name (consent--library-name-key name)))
         (entry (consent--library-catalog-lookup key)))
    (cond
     ((null entry)
      (consent--library-resolution-record
       key
       :status 'missing
       :reason 'missing-library))
     ((and (consent--library-visibility-internal-p
            (plist-get entry :visibility))
           (not (consent--library-internal-import-allowed-p context)))
      (append
       (consent--library-resolution-record
        key
        :entry entry
        :status 'denied
        :reason 'internal-library)
       (list
        (consent--library-record-field
         "required-posture"
         (consent--syntax-symbol "internal-libraries-allowed")))))
     ((not (consent--library-entry-available-p entry))
      (consent--library-resolution-record
       key
       :entry entry
       :status 'unavailable
       :reason 'availability-condition))
     (t
      (consent--library-resolution-record
       key
       :entry entry
       :status 'resolved)))))

(defun consent--library-load-record (name context environment)
  "Resolve and load NAME in CONTEXT, returning a resolution record."
  (let* ((key (if (stringp name) name (consent--library-name-key name)))
         (entry (consent--library-catalog-lookup key)))
    (if (null entry)
        (consent--library-resolution-record
         key
         :status 'missing
         :reason 'missing-library)
      (progn
        (consent--resolve-library (consent-read key) context environment)
        (consent--library-resolution-record
         key
         :entry entry
         :status 'resolved
         :loaded t)))))

(defun consent--library-direct-dependencies (entry)
  "Return direct manifest dependency keys from ENTRY."
  (or (plist-get entry :dependencies) nil))

(defun consent--library-dependency-closure (name)
  "Return transitive dependency keys for NAME in deterministic order."
  (let ((seen nil)
        result)
    (cl-labels ((visit
                 (key)
                 (unless (member key seen)
                   (push key seen)
                   (let ((entry (consent--library-catalog-lookup key)))
                     (dolist (dependency
                              (and
                               entry
                               (consent--library-direct-dependencies entry)))
                       (unless (member dependency result)
                         (push dependency result))
                       (visit dependency))))))
      (visit (if (stringp name) name (consent--library-name-key name))))
    (nreverse result)))

(defun consent--library-solve-dependencies-record (name)
  "Return a Scheme-readable dependency solution record for NAME."
  (let* ((key (if (stringp name) name (consent--library-name-key name)))
         (entry (consent--library-catalog-lookup key)))
    (if entry
        (list
         (consent--syntax-symbol "library-dependencies")
         (consent--library-record-field
          "name"
          (consent--library-record-library-name key))
         (consent--library-record-field
          "status"
          (consent--syntax-symbol "resolved"))
         (consent--library-record-field
          "dependencies"
          (mapcar #'consent-read
                  (consent--library-dependency-closure key))))
      (list
       (consent--syntax-symbol "library-dependencies")
       (consent--library-record-field
        "name"
        (consent--library-record-library-name key))
       (consent--library-record-field
        "status"
        (consent--syntax-symbol "missing"))
       (consent--library-record-field
        "reason"
        (consent--syntax-symbol "missing-library"))
       (consent--library-record-field "dependencies" nil)))))

(defun consent--library-path-record (kind source-id entries precedence)
  "Return a Scheme-readable library-path record."
  (list
   (consent--syntax-symbol "library-path")
   (consent--library-record-field
    "kind"
    (consent--library-record-symbol kind))
   (consent--library-record-field
    "id"
    (consent--library-record-source-id source-id))
   (consent--library-record-field
    "precedence"
    (consent--make-canonical-integer precedence))
   (consent--library-record-field
    "libraries"
    (mapcar
     (lambda (entry)
       (consent-read (plist-get entry :name)))
     entries))))

(defun consent--library-paths ()
  "Return Scheme-readable active library resolution paths."
  (let ((precedence 0)
        result)
    (dolist (source consent--library-catalog-ad-hoc-manifests)
      (push (consent--library-path-record
             'ad-hoc-manifest (car source) (cdr source) precedence)
            result)
      (setq precedence (1+ precedence)))
    (dolist (source consent--library-catalog-root-manifests)
      (push (consent--library-path-record
             'manifest-root (car source) (cdr source) precedence)
            result)
      (setq precedence (1+ precedence)))
    (push (consent--library-path-record
           'built-in-seed
           'built-in-seed
           (consent--library-catalog-built-in-entries)
           precedence)
          result)
    (nreverse result)))

(defun consent--library-conflict-records (&optional library-name)
  "Return conflict resolution records, optionally limited to LIBRARY-NAME."
  (let ((entries (consent--library-catalog-candidate-entries))
        (table (make-hash-table :test #'equal))
        result)
    (dolist (entry entries)
      (push entry (gethash (plist-get entry :name) table)))
    (maphash
     (lambda (key candidates)
       (let ((ordered (nreverse candidates)))
         (when (and (cdr ordered)
                    (or (null library-name)
                        (equal key
                               (if (stringp library-name)
                                   library-name
                                 (consent--library-name-key library-name)))))
           (push
            (consent--library-resolution-record
             key
             :entry (car ordered)
             :status 'conflict
             :reason 'duplicate-library
             :candidates ordered)
            result))))
     table)
    (sort result
          (lambda (left right)
            (string<
             (consent-datum->external
              (cadr (assoc (consent--syntax-symbol "name") (cdr left))))
             (consent-datum->external
              (cadr (assoc (consent--syntax-symbol "name") (cdr right)))))))))

(defun consent--library-snapshot-record (name context)
  "Return a reproducible resolution snapshot for NAME."
  (let* ((key (if (stringp name) name (consent--library-name-key name)))
         (dependencies (consent--library-dependency-closure key))
         (keys (cons key dependencies)))
    (list
     (consent--syntax-symbol "library-snapshot")
     (consent--library-record-field
      "name"
      (consent--library-record-library-name key))
     (consent--library-record-field
      "status"
      (consent--syntax-symbol "resolved"))
     (consent--library-record-field
      "resolved"
      (mapcar
       (lambda (entry-key)
         (consent--library-resolve-record entry-key context))
       keys)))))

(defun consent--library-srfi-number (value)
  "Return VALUE as a non-negative SRFI number."
  (cond
   ((and (integerp value) (>= value 0)) value)
   ((and (consent-number-p value)
         (eq (consent-number-kind value) 'integer)
         (eq (consent-number-exactness value) 'exact)
         (>= (consent-number-value value) 0))
    (consent-number-value value))
   (t
    (consent--eval-error "SRFI number must be a non-negative exact integer"))))

(defun consent--library-srfi-key (number)
  "Return canonical SRFI library key for NUMBER."
  (format "(srfi %d)" (consent--library-srfi-number number)))

(defun consent--library-srfi-name (number)
  "Return canonical SRFI library name for NUMBER."
  (consent-read (consent--library-srfi-key number)))

(defun consent--library-srfi-aliases (number)
  "Return known SRFI aliases for NUMBER."
  (let* ((key (consent--library-srfi-key number))
         (entry (consent--library-catalog-lookup key))
         (aliases
          (delete-dups
           (copy-sequence
            (cons key (or (plist-get entry :aliases) nil))))))
    (mapcar #'consent-read aliases)))

(defun consent--library-vendored-srfi-entry (number)
  "Return catalog entry for vendored SRFI NUMBER, or nil."
  (consent--library-catalog-lookup
   (consent--library-srfi-key number)))

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

(defun consent--manifest-source-library-file (source-file &optional root)
  "Return absolute path for root-relative manifest SOURCE-FILE."
  (expand-file-name source-file
                    (or root (consent--library-default-manifest-root))))

(defun consent--manifest-source-library-source (source-file key &optional root)
  "Return source text for root-relative SOURCE-FILE owned by KEY."
  (let ((path (consent--manifest-source-library-file source-file root)))
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
        (root (plist-get entry :root))
        (exports (plist-get entry :exports))
        (overlay-library (plist-get entry :primitive-overlay-library)))
    (unless source-file
      (consent--eval-error
       "manifest source library has no source-file: %s"
       key))
    (unless (gethash key (consent--eval-context-libraries context))
      (consent--register-source-library
       (consent--manifest-source-library-source source-file key root)
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

(defun consent--primitive-library-require-property (entry property)
  "Return ENTRY PROPERTY, requiring that the key is present."
  (unless (plist-member entry property)
    (consent--eval-error
     "primitive-library declaration missing property: %s"
     property))
  (plist-get entry property))

(defun consent--primitive-library-validate-export (export declaration)
  "Validate primitive EXPORT metadata for DECLARATION."
  (let ((name
         (consent--primitive-library-require-property export :name))
        (primitive
         (consent--primitive-library-require-property export :primitive))
        (arity
         (consent--primitive-library-require-property export :arity)))
    (unless (stringp name)
      (consent--eval-error
       "primitive export name must be a string: %s"
       (plist-get declaration :name)))
    (unless (symbolp primitive)
      (consent--eval-error
       "primitive export implementation must be a symbol: %s"
       name))
    (unless (and (consp arity)
                 (= (length arity) 2)
                 (integerp (car arity))
                 (>= (car arity) 0)
                 (or (null (cadr arity))
                     (and (integerp (cadr arity))
                          (>= (cadr arity) 0)))
                 (or (null (cadr arity))
                     (<= (car arity) (cadr arity))))
      (consent--eval-error
       "primitive export arity must be (minimum maximum): %s"
       name))
    (unless (plist-member export :effects)
      (consent--eval-error
       "primitive export missing effects metadata: %s"
       name))
    (unless (plist-member export :capabilities)
      (consent--eval-error
       "primitive export missing capabilities metadata: %s"
       name))
    (dolist (effect (plist-get export :effects))
      (unless (symbolp effect)
        (consent--eval-error
         "primitive export effects must be symbols: %s"
         name)))
    (dolist (capability (plist-get export :capabilities))
      (unless (symbolp capability)
        (consent--eval-error
         "primitive export capabilities must be symbols: %s"
         name)))
    t))

(defun consent--primitive-library-validate-declaration (declaration)
  "Validate and return primitive-library DECLARATION metadata."
  (unless (eq (plist-get declaration :kind) 'primitive-library)
    (consent--eval-error
     "primitive-library declaration must have kind primitive-library: %s"
     (plist-get declaration :name)))
  (unless (eq (plist-get declaration :source-kind) 'primitive)
    (consent--eval-error
     "primitive-library declaration must have source-kind primitive-library: %s"
     (plist-get declaration :name)))
  (dolist (property '(:name :owner :provider :visibility :layer
                      :implementation-id :implementation-resolver
                      :exports :primitive-exports))
    (consent--primitive-library-require-property declaration property))
  (let ((exports (plist-get declaration :exports))
        (primitive-exports (plist-get declaration :primitive-exports))
        (names nil))
    (unless (and (stringp (plist-get declaration :name))
                 (symbolp (plist-get declaration :owner))
                 (symbolp (plist-get declaration :provider))
                 (symbolp (plist-get declaration :visibility))
                 (symbolp (plist-get declaration :layer))
                 (symbolp (plist-get declaration :implementation-id)))
      (consent--eval-error
       "primitive-library declaration has invalid identity metadata: %s"
       (plist-get declaration :name)))
    (unless (and (consp exports)
                 (cl-every #'stringp exports))
      (consent--eval-error
       "primitive-library declaration must declare exported names: %s"
       (plist-get declaration :name)))
    (unless (consp primitive-exports)
      (consent--eval-error
       "primitive-library declaration must declare primitive exports: %s"
       (plist-get declaration :name)))
    (dolist (export primitive-exports)
      (consent--primitive-library-validate-export export declaration)
      (let ((name (plist-get export :name)))
        (when (member name names)
          (consent--eval-error
           "duplicate primitive export in declaration: %s"
           name))
        (push name names)))
    (dolist (name exports)
      (unless (member name names)
        (consent--eval-error
         "primitive-library export lacks primitive metadata: %s"
         name)))
    (dolist (name names)
      (unless (member name exports)
        (consent--eval-error
         "primitive-library primitive metadata is not exported: %s"
         name))))
  declaration)

(defun consent--primitive-library-declaration-for-entry (entry)
  "Return validated primitive-library declaration for manifest ENTRY, or nil."
  (when (and entry (plist-get entry :primitive-exports))
    (consent--primitive-library-validate-declaration entry)))

(defun consent--primitive-library-declaration-key (name)
  "Return primitive declaration key for NAME."
  (if (stringp name)
      name
    (consent--library-name-key name)))

(defun consent--primitive-library-declaration-for-name (name)
  "Return provider-owned primitive-library declaration named NAME, or nil."
  (let* ((key (consent--primitive-library-declaration-key name))
         (registered
          (seq-find
           (lambda (declaration)
             (equal key (plist-get declaration :name)))
           consent--primitive-library-provider-declarations)))
    (or registered
        (consent--primitive-library-declaration-for-entry
         (consent--library-collection-manifest-entry key)))))

(defun consent--primitive-library-register-declaration
    (declaration &optional replace)
  "Register provider-owned primitive-library DECLARATION.
When REPLACE is non-nil, replace an existing declaration from the same provider."
  (let* ((validated
          (consent--primitive-library-validate-declaration declaration))
         (name (plist-get validated :name))
         (provider (plist-get validated :provider))
         (existing
          (seq-find
           (lambda (candidate)
             (equal name (plist-get candidate :name)))
           consent--primitive-library-provider-declarations)))
    (cond
     ((null existing)
      (push validated consent--primitive-library-provider-declarations)
      t)
     ((not (eq provider (plist-get existing :provider)))
      (consent--eval-error
       "primitive-library declaration provider conflict: %s"
       name))
     ((equal validated existing) t)
     (replace
      (setq consent--primitive-library-provider-declarations
            (cons validated
                  (seq-remove
                   (lambda (candidate)
                     (and (equal name (plist-get candidate :name))
                          (eq provider (plist-get candidate :provider))))
                   consent--primitive-library-provider-declarations)))
      t)
     (t
      (consent--eval-error
       "primitive-library declaration duplicate differs: %s"
       name)))))

(defun consent--primitive-library-remove-declaration (name provider)
  "Remove provider-owned primitive-library declaration NAME from PROVIDER."
  (let* ((key (consent--primitive-library-declaration-key name))
         (removed nil))
    (setq consent--primitive-library-provider-declarations
          (seq-remove
           (lambda (declaration)
             (let ((match
                    (and (equal key (plist-get declaration :name))
                         (eq provider
                             (plist-get declaration :provider)))))
               (when match
                 (setq removed t))
               match))
           consent--primitive-library-provider-declarations))
    removed))

(defun consent--primitive-library-resolver-field (resolver field)
  "Return FIELD from primitive implementation RESOLVER metadata."
  (catch 'field
    (dolist (candidate
             (consent--proper-list-elements
              resolver
              "primitive implementation resolver"))
      (let ((parts
             (and (consp candidate)
                  (consent--proper-list-elements
                   candidate
                   "primitive implementation resolver field"))))
        (when (and parts
                   (consent--symbol-named-p (car parts) field)
                   (= (length parts) 2))
          (throw 'field (cadr parts)))))
    (consent--eval-error
     "primitive implementation resolver missing field: %s"
     field)))

(defun consent--primitive-library-implementation-resolver (declaration)
  "Return implementation resolver function for primitive DECLARATION."
  (let* ((resolver
          (consent--primitive-library-require-property
           declaration :implementation-resolver))
         (module
          (consent--collection-manifest-symbol
           (consent--primitive-library-resolver-field resolver "module")
           "primitive implementation resolver module"))
         (procedure
          (consent--collection-manifest-symbol
           (consent--primitive-library-resolver-field resolver "procedure")
           "primitive implementation resolver procedure")))
    (require module)
    (unless (fboundp procedure)
      (consent--eval-error
       "primitive implementation resolver is not defined: %s"
       procedure))
    (symbol-function procedure)))

(defun consent--primitive-library-declaration-specs (declaration)
  "Materialize primitive specs from provider-owned DECLARATION."
  (let ((resolver
         (consent--primitive-library-implementation-resolver
          (consent--primitive-library-validate-declaration declaration))))
    (mapcar
     (lambda (export)
       (let* ((arity (plist-get export :arity))
              (implementation
               (funcall resolver (plist-get export :primitive))))
         (unless (or (functionp implementation)
                     (and (symbolp implementation)
                          (fboundp implementation)))
           (consent--eval-error
            "primitive resolver returned non-function: %s"
            (plist-get export :primitive)))
         (list (plist-get export :name)
               implementation
               (car arity)
               (cadr arity))))
     (plist-get declaration :primitive-exports))))

(defun consent--manifest-primitive-implementation-specs (entry)
  "Return primitive specs for manifest primitive implementation ENTRY."
  (let ((declaration
         (consent--primitive-library-declaration-for-entry entry)))
    (if declaration
        (consent--primitive-library-declaration-specs declaration)
      (consent--eval-error
       "manifest primitive library lacks provider declaration: %s"
       (plist-get entry :name)))))

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
         (and (consent--manifest-primitive-implementation-specs entry) t)
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
  (let ((max-lisp-eval-depth
         (max max-lisp-eval-depth consent--source-library-lisp-eval-depth))
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
         (entry (consent--library-catalog-lookup key)))
    (and
     (or (not (consent--library-visibility-internal-p
               (or (plist-get entry :visibility)
                   (consent--library-visibility key))))
         (consent--library-internal-import-allowed-p context))
     (or (not entry)
         (consent--library-entry-available-p entry))
     (or (consent--manifest-library-routable-p entry)
         (and (gethash key (consent--eval-context-libraries context))
              t)))))

(defun consent--resolve-library (name context environment)
  "Return library NAME from CONTEXT, registering builtins when needed."
  (let* ((key (consent--library-name-key name))
         (entry (consent--library-catalog-lookup key)))
    (consent--ensure-library-import-allowed key context entry)
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
    (member (consent--symbol-name requirement) '("r7rs" "consent")))
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
