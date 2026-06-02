;;; consent-host-adapter-fixture-test.el --- Host adapter fixture tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Validates the Scheme-readable Emacs host-adapter declaration fixture against
;; the current Emacs capability manifest and library registry.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-capability)
(require 'consent-library)
(require 'consent-reader)
(require 'consent-result)

(defconst consent-host-adapter-fixture-test--fixture-path
  "fixtures/host-adapters/emacs.scm"
  "Repository-relative path to the Emacs host-adapter fixture.")

(defun consent-host-adapter-fixture-test--read-file (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file consent--test-root))
    (buffer-string)))

(defun consent-host-adapter-fixture-test--fixture ()
  "Return the parsed Emacs host-adapter fixture datum."
  (let* ((path (expand-file-name
                consent-host-adapter-fixture-test--fixture-path
                consent--test-root))
         (forms (consent-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (car forms)))

(defun consent-host-adapter-fixture-test--symbol-name (value)
  "Return VALUE as a stable symbol name when possible."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((null value)
    nil)
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun consent-host-adapter-fixture-test--named-p (datum name)
  "Return non-nil when DATUM is a list whose first symbol is NAME."
  (and (consp datum)
       (equal (consent-host-adapter-fixture-test--symbol-name (car datum))
              name)))

(defun consent-host-adapter-fixture-test--field (record name)
  "Return RECORD field named NAME."
  (if (consent-host-adapter-fixture-test--named-p record name)
      record
    (let ((fields (if (consp (car-safe record))
                      record
                    (cdr-safe record))))
      (seq-find
       (lambda (field)
         (consent-host-adapter-fixture-test--named-p field name))
       fields))))

(defun consent-host-adapter-fixture-test--field-value (record name)
  "Return the first value of RECORD field NAME."
  (cadr (consent-host-adapter-fixture-test--field record name)))

(defun consent-host-adapter-fixture-test--section (fixture name)
  "Return top-level FIXTURE section NAME."
  (consent-host-adapter-fixture-test--field-value fixture name))

(defun consent-host-adapter-fixture-test--library-key (library-datum)
  "Return LIBRARY-DATUM as external library-name text."
  (consent-datum->external library-datum))

(defun consent-host-adapter-fixture-test--library-record-key
    (library-record)
  "Return a `(library ...)' record's library key as text."
  (consent-host-adapter-fixture-test--library-key
   (consent-host-adapter-fixture-test--field-value
    library-record "library")))

(defun consent-host-adapter-fixture-test--record-symbol-field
    (record name)
  "Return RECORD field NAME as a symbol name."
  (consent-host-adapter-fixture-test--symbol-name
   (consent-host-adapter-fixture-test--field-value record name)))

(defun consent-host-adapter-fixture-test--sorted-strings (strings)
  "Return STRINGS sorted with `string<'."
  (sort (copy-sequence strings) #'string<))

(defun consent-host-adapter-fixture-test--adapter-provides (adapter)
  "Return provided library records from ADAPTER."
  (consent-host-adapter-fixture-test--field-value adapter "provides"))

(defun consent-host-adapter-fixture-test--emacs-provided-library-keys
    (adapter)
  "Return Emacs library keys declared by ADAPTER."
  (seq-filter
   (lambda (key)
     (string-prefix-p "(emacs " key))
   (mapcar
    #'consent-host-adapter-fixture-test--library-record-key
    (consent-host-adapter-fixture-test--adapter-provides adapter))))

(defun consent-host-adapter-fixture-test--agent-provided-library-keys
    (adapter)
  "Return Agent library keys declared by ADAPTER."
  (seq-filter
   (lambda (key)
     (string-prefix-p "(agent " key))
   (mapcar
    #'consent-host-adapter-fixture-test--library-record-key
    (consent-host-adapter-fixture-test--adapter-provides adapter))))

(defun consent-host-adapter-fixture-test--consent-provided-library-keys
    (adapter)
  "Return consent core library keys declared by ADAPTER."
  (seq-filter
   (lambda (key)
     (string-prefix-p "(consent " key))
   (mapcar
    #'consent-host-adapter-fixture-test--library-record-key
    (consent-host-adapter-fixture-test--adapter-provides adapter))))

(defun consent-host-adapter-fixture-test--capabilities (manifest)
  "Return capability records from MANIFEST."
  (consent-host-adapter-fixture-test--field-value manifest "capabilities"))

(defun consent-host-adapter-fixture-test--capability-key (capability)
  "Return CAPABILITY's stable library/name key."
  (cons
   (consent-host-adapter-fixture-test--library-key
    (consent-host-adapter-fixture-test--field-value capability "library"))
   (consent-host-adapter-fixture-test--record-symbol-field
    capability "name")))

(defun consent-host-adapter-fixture-test--capability-spec-key (spec)
  "Return SPEC's stable library/name key."
  (cons (plist-get spec :library) (plist-get spec :name)))

(defun consent-host-adapter-fixture-test--capability-less-p (left right)
  "Return non-nil when capability key LEFT sorts before RIGHT."
  (let ((left-text (format "%s/%s" (car left) (cdr left)))
        (right-text (format "%s/%s" (car right) (cdr right))))
    (string< left-text right-text)))

(defun consent-host-adapter-fixture-test--capability-by-key
    (capabilities key)
  "Return capability record in CAPABILITIES matching KEY."
  (seq-find
   (lambda (capability)
     (equal (consent-host-adapter-fixture-test--capability-key capability)
            key))
   capabilities))

(defun consent-host-adapter-fixture-test--declared-symbols
    (records name)
  "Return symbol values from field NAME across RECORDS."
  (mapcar
   (lambda (record)
     (consent-host-adapter-fixture-test--record-symbol-field record name))
   records))

(ert-deftest consent-host-adapter-fixture-test-parses-declaration ()
  "The Emacs host-adapter fixture is Scheme-readable data."
  (let* ((fixture (consent-host-adapter-fixture-test--fixture))
         (adapter (consent-host-adapter-fixture-test--section
                   fixture "adapter"))
         (manifest (consent-host-adapter-fixture-test--section
                    fixture "capability-manifest"))
         (provides (consent-host-adapter-fixture-test--adapter-provides
                    adapter)))
    (should
     (consent-host-adapter-fixture-test--named-p
      fixture "consent-host-adapter-fixture"))
    (should
     (consent-host-adapter-fixture-test--named-p adapter "host-adapter"))
    (should
     (consent-host-adapter-fixture-test--named-p
      manifest "capability-manifest"))
    (should (equal (consent-host-adapter-fixture-test--record-symbol-field
                    adapter "name")
                   "emacs"))
    (should (equal (consent-host-adapter-fixture-test--record-symbol-field
                    adapter "contract")
                   "r7rs-small"))
    (dolist (required '("(consent capability)"
                        "(agent approval)"
                        "(agent io)"
                        "(agent session)"))
      (should
       (member required
               (mapcar
                #'consent-host-adapter-fixture-test--library-record-key
                provides))))
    (dolist (required '("editor" "batch"))
      (should
       (member required
               (mapcar
                #'consent-host-adapter-fixture-test--symbol-name
                (consent-host-adapter-fixture-test--field-value
                 adapter "modes")))))))

(ert-deftest consent-host-adapter-fixture-test-version-matches-runtime ()
  "The host-adapter declaration points at the canonical version source."
  (let* ((fixture (consent-host-adapter-fixture-test--fixture))
         (adapter (consent-host-adapter-fixture-test--section
                   fixture "adapter"))
         (implementation (consent-host-adapter-fixture-test--field-value
                          adapter "implementation"))
         (version-source-file
          (consent-host-adapter-fixture-test--field-value
           implementation "version-source-file")))
    (should (equal version-source-file "scheme/consent/version.sld"))
    (should (file-exists-p
             (expand-file-name version-source-file consent--test-root)))
    (should (equal (consent-host-adapter-fixture-test--record-symbol-field
                    implementation "version-binding")
                   "consent-version-datum"))
    (should (equal (consent-host-adapter-fixture-test--record-symbol-field
                    implementation "version-source")
                   "roadmap-derived"))))

(ert-deftest consent-host-adapter-fixture-test-libraries-match-registry ()
  "Declared Emacs and shared agent libraries align with registries."
  (let* ((fixture (consent-host-adapter-fixture-test--fixture))
         (adapter (consent-host-adapter-fixture-test--section
                   fixture "adapter")))
    (should
     (equal
      (consent-host-adapter-fixture-test--sorted-strings
       (consent-host-adapter-fixture-test--emacs-provided-library-keys
        adapter))
      (consent-host-adapter-fixture-test--sorted-strings
       (consent-emacs-capability-library-keys))))
    (should
     (equal
      (consent-host-adapter-fixture-test--sorted-strings
       (consent-host-adapter-fixture-test--agent-provided-library-keys
        adapter))
      (consent-host-adapter-fixture-test--sorted-strings
       consent--agent-library-keys)))
    (should
     (equal
      (consent-host-adapter-fixture-test--sorted-strings
       (consent-host-adapter-fixture-test--consent-provided-library-keys
        adapter))
      (consent-host-adapter-fixture-test--sorted-strings
       consent--consent-library-keys)))))

(ert-deftest consent-host-adapter-fixture-test-manifest-matches-bindings ()
  "Declared host-capability records track the Emacs capability manifest."
  (let* ((fixture (consent-host-adapter-fixture-test--fixture))
         (manifest (consent-host-adapter-fixture-test--section
                    fixture "capability-manifest"))
         (capabilities (consent-host-adapter-fixture-test--capabilities
                        manifest))
         (capability-keys
          (sort
           (mapcar #'consent-host-adapter-fixture-test--capability-key
                   capabilities)
           #'consent-host-adapter-fixture-test--capability-less-p))
         (specs (consent-emacs-capability-binding-specs))
         (spec-keys
          (sort
           (mapcar #'consent-host-adapter-fixture-test--capability-spec-key
                   specs)
           #'consent-host-adapter-fixture-test--capability-less-p)))
    (should (equal capability-keys spec-keys))
    (dolist (spec specs)
      (let* ((key (consent-host-adapter-fixture-test--capability-spec-key
                   spec))
             (capability
              (consent-host-adapter-fixture-test--capability-by-key
               capabilities key)))
        (should capability)
        (should (equal
                 (consent-host-adapter-fixture-test--record-symbol-field
                  capability "effect")
                 (symbol-name (plist-get spec :effect))))
        (should (equal
                 (consent-host-adapter-fixture-test--record-symbol-field
                  capability "required-capability")
                 (symbol-name (plist-get spec :required-capability))))
        (should (equal
                 (consent-host-adapter-fixture-test--record-symbol-field
                  capability "policy-category")
                 (symbol-name (plist-get spec :policy-category))))
        (should (equal
                 (consent-host-adapter-fixture-test--record-symbol-field
                  capability "policy")
                 (symbol-name (plist-get spec :policy))))
        (should (equal
                 (consent-host-adapter-fixture-test--record-symbol-field
                  capability "effect-path")
                 (symbol-name (plist-get spec :backend-effect-path))))))))

(ert-deftest consent-host-adapter-fixture-test-covers-authority-and-handles ()
  "Authority classes and handle kinds cover current Emacs adapter surfaces."
  (let* ((fixture (consent-host-adapter-fixture-test--fixture))
         (adapter (consent-host-adapter-fixture-test--section
                   fixture "adapter"))
         (manifest (consent-host-adapter-fixture-test--section
                    fixture "capability-manifest"))
         (authority (consent-host-adapter-fixture-test--field-value
                     adapter "authority"))
         (handle-kinds (consent-host-adapter-fixture-test--field-value
                        adapter "handle-kinds"))
         (capabilities (consent-host-adapter-fixture-test--capabilities
                        manifest)))
    (dolist (required '("read-only-observation"
                        "buffer-edit"
                        "window-session"
                        "command-process"
                        "vcs-mutation"
                        "network-access"
                        "audit-observation"))
      (should
       (member required
               (consent-host-adapter-fixture-test--declared-symbols
                authority "class"))))
    (dolist (required '("buffer" "window" "frame" "project" "process"
                        "command" "audit-entry"))
      (should
       (member required
               (consent-host-adapter-fixture-test--declared-symbols
                handle-kinds "kind"))))
    (dolist (required '("read-only-observation"
                        "buffer-edit"
                        "window-session"
                        "command-process"
                        "network-access"))
      (should
       (member required
               (consent-host-adapter-fixture-test--declared-symbols
                capabilities "authority"))))))

(ert-deftest consent-host-adapter-fixture-test-documents-discovery ()
  "Docs point Emacs host discovery at the shared adapter fixture shape."
  (let ((doc (consent-host-adapter-fixture-test--read-file
              "docs/feature-reflection.md")))
    (dolist (needle
             `(,consent-host-adapter-fixture-test--fixture-path
               "(name emacs)"
               "same `host-adapter` declaration shape"
               "Emacs-specific facilities"))
      (should (string-match-p (regexp-quote needle) doc)))))

;;; consent-host-adapter-fixture-test.el ends here
