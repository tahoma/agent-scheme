;;; agent-scheme-host-adapter-fixture-test.el --- Host adapter fixture tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Validates the Scheme-readable Emacs host-adapter declaration fixture against
;; the current Emacs capability manifest and library registry.

;;; Code:

(require 'ert)
(require 'seq)
(require 'agent-scheme-capability)
(require 'agent-scheme-library)
(require 'agent-scheme-reader)
(require 'agent-scheme-result)

(defconst agent-scheme-host-adapter-fixture-test--fixture-path
  "fixtures/host-adapters/emacs.scm"
  "Repository-relative path to the Emacs host-adapter fixture.")

(defun agent-scheme-host-adapter-fixture-test--read-file (relative-file)
  "Return the contents of RELATIVE-FILE under the repository root."
  (with-temp-buffer
    (insert-file-contents (expand-file-name relative-file agent-scheme--test-root))
    (buffer-string)))

(defun agent-scheme-host-adapter-fixture-test--fixture ()
  "Return the parsed Emacs host-adapter fixture datum."
  (let* ((path (expand-file-name
                agent-scheme-host-adapter-fixture-test--fixture-path
                agent-scheme--test-root))
         (forms (agent-scheme-read-all
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))))
    (should (= (length forms) 1))
    (car forms)))

(defun agent-scheme-host-adapter-fixture-test--symbol-name (value)
  "Return VALUE as a stable symbol name when possible."
  (cond
   ((agent-scheme-symbol-p value)
    (agent-scheme-symbol-name value))
   ((null value)
    nil)
   ((symbolp value)
    (symbol-name value))
   (t nil)))

(defun agent-scheme-host-adapter-fixture-test--named-p (datum name)
  "Return non-nil when DATUM is a list whose first symbol is NAME."
  (and (consp datum)
       (equal (agent-scheme-host-adapter-fixture-test--symbol-name (car datum))
              name)))

(defun agent-scheme-host-adapter-fixture-test--field (record name)
  "Return RECORD field named NAME."
  (if (agent-scheme-host-adapter-fixture-test--named-p record name)
      record
    (let ((fields (if (consp (car-safe record))
                      record
                    (cdr-safe record))))
      (seq-find
       (lambda (field)
         (agent-scheme-host-adapter-fixture-test--named-p field name))
       fields))))

(defun agent-scheme-host-adapter-fixture-test--field-value (record name)
  "Return the first value of RECORD field NAME."
  (cadr (agent-scheme-host-adapter-fixture-test--field record name)))

(defun agent-scheme-host-adapter-fixture-test--section (fixture name)
  "Return top-level FIXTURE section NAME."
  (agent-scheme-host-adapter-fixture-test--field-value fixture name))

(defun agent-scheme-host-adapter-fixture-test--library-key (library-datum)
  "Return LIBRARY-DATUM as external library-name text."
  (agent-scheme-datum->external library-datum))

(defun agent-scheme-host-adapter-fixture-test--library-record-key
    (library-record)
  "Return a `(library ...)' record's library key as text."
  (agent-scheme-host-adapter-fixture-test--library-key
   (agent-scheme-host-adapter-fixture-test--field-value
    library-record "library")))

(defun agent-scheme-host-adapter-fixture-test--record-symbol-field
    (record name)
  "Return RECORD field NAME as a symbol name."
  (agent-scheme-host-adapter-fixture-test--symbol-name
   (agent-scheme-host-adapter-fixture-test--field-value record name)))

(defun agent-scheme-host-adapter-fixture-test--sorted-strings (strings)
  "Return STRINGS sorted with `string<'."
  (sort (copy-sequence strings) #'string<))

(defun agent-scheme-host-adapter-fixture-test--adapter-provides (adapter)
  "Return provided library records from ADAPTER."
  (agent-scheme-host-adapter-fixture-test--field-value adapter "provides"))

(defun agent-scheme-host-adapter-fixture-test--emacs-provided-library-keys
    (adapter)
  "Return Emacs library keys declared by ADAPTER."
  (seq-filter
   (lambda (key)
     (string-prefix-p "(emacs " key))
   (mapcar
    #'agent-scheme-host-adapter-fixture-test--library-record-key
    (agent-scheme-host-adapter-fixture-test--adapter-provides adapter))))

(defun agent-scheme-host-adapter-fixture-test--agent-provided-library-keys
    (adapter)
  "Return Agent library keys declared by ADAPTER."
  (seq-filter
   (lambda (key)
     (string-prefix-p "(agent " key))
   (mapcar
    #'agent-scheme-host-adapter-fixture-test--library-record-key
    (agent-scheme-host-adapter-fixture-test--adapter-provides adapter))))

(defun agent-scheme-host-adapter-fixture-test--capabilities (manifest)
  "Return capability records from MANIFEST."
  (agent-scheme-host-adapter-fixture-test--field-value manifest "capabilities"))

(defun agent-scheme-host-adapter-fixture-test--capability-key (capability)
  "Return CAPABILITY's stable library/name key."
  (cons
   (agent-scheme-host-adapter-fixture-test--library-key
    (agent-scheme-host-adapter-fixture-test--field-value capability "library"))
   (agent-scheme-host-adapter-fixture-test--record-symbol-field
    capability "name")))

(defun agent-scheme-host-adapter-fixture-test--capability-spec-key (spec)
  "Return SPEC's stable library/name key."
  (cons (plist-get spec :library) (plist-get spec :name)))

(defun agent-scheme-host-adapter-fixture-test--capability-less-p (left right)
  "Return non-nil when capability key LEFT sorts before RIGHT."
  (let ((left-text (format "%s/%s" (car left) (cdr left)))
        (right-text (format "%s/%s" (car right) (cdr right))))
    (string< left-text right-text)))

(defun agent-scheme-host-adapter-fixture-test--capability-by-key
    (capabilities key)
  "Return capability record in CAPABILITIES matching KEY."
  (seq-find
   (lambda (capability)
     (equal (agent-scheme-host-adapter-fixture-test--capability-key capability)
            key))
   capabilities))

(defun agent-scheme-host-adapter-fixture-test--declared-symbols
    (records name)
  "Return symbol values from field NAME across RECORDS."
  (mapcar
   (lambda (record)
     (agent-scheme-host-adapter-fixture-test--record-symbol-field record name))
   records))

(ert-deftest agent-scheme-host-adapter-fixture-test-parses-declaration ()
  "The Emacs host-adapter fixture is Scheme-readable data."
  (let* ((fixture (agent-scheme-host-adapter-fixture-test--fixture))
         (adapter (agent-scheme-host-adapter-fixture-test--section
                   fixture "adapter"))
         (manifest (agent-scheme-host-adapter-fixture-test--section
                    fixture "capability-manifest"))
         (provides (agent-scheme-host-adapter-fixture-test--adapter-provides
                    adapter)))
    (should
     (agent-scheme-host-adapter-fixture-test--named-p
      fixture "agent-scheme-host-adapter-fixture"))
    (should
     (agent-scheme-host-adapter-fixture-test--named-p adapter "host-adapter"))
    (should
     (agent-scheme-host-adapter-fixture-test--named-p
      manifest "capability-manifest"))
    (should (equal (agent-scheme-host-adapter-fixture-test--record-symbol-field
                    adapter "name")
                   "emacs"))
    (should (equal (agent-scheme-host-adapter-fixture-test--record-symbol-field
                    adapter "contract")
                   "r7rs-small"))
    (dolist (required '("(agent capability)"
                        "(agent approval)"
                        "(agent io)"
                        "(agent session)"))
      (should
       (member required
               (mapcar
                #'agent-scheme-host-adapter-fixture-test--library-record-key
                provides))))
    (dolist (required '("editor" "batch"))
      (should
       (member required
               (mapcar
                #'agent-scheme-host-adapter-fixture-test--symbol-name
                (agent-scheme-host-adapter-fixture-test--field-value
                 adapter "modes")))))))

(ert-deftest agent-scheme-host-adapter-fixture-test-version-matches-runtime ()
  "The host-adapter declaration points at the canonical version source."
  (let* ((fixture (agent-scheme-host-adapter-fixture-test--fixture))
         (adapter (agent-scheme-host-adapter-fixture-test--section
                   fixture "adapter"))
         (implementation (agent-scheme-host-adapter-fixture-test--field-value
                          adapter "implementation"))
         (version-source-file
          (agent-scheme-host-adapter-fixture-test--field-value
           implementation "version-source-file")))
    (should (equal version-source-file "scheme/agent-scheme/version.sld"))
    (should (file-exists-p
             (expand-file-name version-source-file agent-scheme--test-root)))
    (should (equal (agent-scheme-host-adapter-fixture-test--record-symbol-field
                    implementation "version-binding")
                   "agent-scheme-version-datum"))
    (should (equal (agent-scheme-host-adapter-fixture-test--record-symbol-field
                    implementation "version-source")
                   "roadmap-derived"))))

(ert-deftest agent-scheme-host-adapter-fixture-test-libraries-match-registry ()
  "Declared Emacs and shared agent libraries align with registries."
  (let* ((fixture (agent-scheme-host-adapter-fixture-test--fixture))
         (adapter (agent-scheme-host-adapter-fixture-test--section
                   fixture "adapter")))
    (should
     (equal
      (agent-scheme-host-adapter-fixture-test--sorted-strings
       (agent-scheme-host-adapter-fixture-test--emacs-provided-library-keys
        adapter))
      (agent-scheme-host-adapter-fixture-test--sorted-strings
       (agent-scheme-emacs-capability-library-keys))))
    (should
     (equal
      (agent-scheme-host-adapter-fixture-test--sorted-strings
       (agent-scheme-host-adapter-fixture-test--agent-provided-library-keys
        adapter))
      (agent-scheme-host-adapter-fixture-test--sorted-strings
       agent-scheme--agent-library-keys)))))

(ert-deftest agent-scheme-host-adapter-fixture-test-manifest-matches-bindings ()
  "Declared host-capability records track the Emacs capability manifest."
  (let* ((fixture (agent-scheme-host-adapter-fixture-test--fixture))
         (manifest (agent-scheme-host-adapter-fixture-test--section
                    fixture "capability-manifest"))
         (capabilities (agent-scheme-host-adapter-fixture-test--capabilities
                        manifest))
         (capability-keys
          (sort
           (mapcar #'agent-scheme-host-adapter-fixture-test--capability-key
                   capabilities)
           #'agent-scheme-host-adapter-fixture-test--capability-less-p))
         (specs (agent-scheme-emacs-capability-binding-specs))
         (spec-keys
          (sort
           (mapcar #'agent-scheme-host-adapter-fixture-test--capability-spec-key
                   specs)
           #'agent-scheme-host-adapter-fixture-test--capability-less-p)))
    (should (equal capability-keys spec-keys))
    (dolist (spec specs)
      (let* ((key (agent-scheme-host-adapter-fixture-test--capability-spec-key
                   spec))
             (capability
              (agent-scheme-host-adapter-fixture-test--capability-by-key
               capabilities key)))
        (should capability)
        (should (equal
                 (agent-scheme-host-adapter-fixture-test--record-symbol-field
                  capability "effect")
                 (symbol-name (plist-get spec :effect))))
        (should (equal
                 (agent-scheme-host-adapter-fixture-test--record-symbol-field
                  capability "required-capability")
                 (symbol-name (plist-get spec :required-capability))))
        (should (equal
                 (agent-scheme-host-adapter-fixture-test--record-symbol-field
                  capability "policy-category")
                 (symbol-name (plist-get spec :policy-category))))
        (should (equal
                 (agent-scheme-host-adapter-fixture-test--record-symbol-field
                  capability "policy")
                 (symbol-name (plist-get spec :policy))))
        (should (equal
                 (agent-scheme-host-adapter-fixture-test--record-symbol-field
                  capability "effect-path")
                 (symbol-name (plist-get spec :backend-effect-path))))))))

(ert-deftest agent-scheme-host-adapter-fixture-test-covers-authority-and-handles ()
  "Authority classes and handle kinds cover current Emacs adapter surfaces."
  (let* ((fixture (agent-scheme-host-adapter-fixture-test--fixture))
         (adapter (agent-scheme-host-adapter-fixture-test--section
                   fixture "adapter"))
         (manifest (agent-scheme-host-adapter-fixture-test--section
                    fixture "capability-manifest"))
         (authority (agent-scheme-host-adapter-fixture-test--field-value
                     adapter "authority"))
         (handle-kinds (agent-scheme-host-adapter-fixture-test--field-value
                        adapter "handle-kinds"))
         (capabilities (agent-scheme-host-adapter-fixture-test--capabilities
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
               (agent-scheme-host-adapter-fixture-test--declared-symbols
                authority "class"))))
    (dolist (required '("buffer" "window" "frame" "project" "process"
                        "command" "audit-entry"))
      (should
       (member required
               (agent-scheme-host-adapter-fixture-test--declared-symbols
                handle-kinds "kind"))))
    (dolist (required '("read-only-observation"
                        "buffer-edit"
                        "window-session"
                        "command-process"
                        "network-access"))
      (should
       (member required
               (agent-scheme-host-adapter-fixture-test--declared-symbols
                capabilities "authority"))))))

(ert-deftest agent-scheme-host-adapter-fixture-test-documents-discovery ()
  "Docs point Emacs host discovery at the shared adapter fixture shape."
  (let ((doc (agent-scheme-host-adapter-fixture-test--read-file
              "docs/feature-reflection.md")))
    (dolist (needle
             `(,agent-scheme-host-adapter-fixture-test--fixture-path
               "(name emacs)"
               "same `host-adapter` declaration shape"
               "Emacs-specific facilities"))
      (should (string-match-p (regexp-quote needle) doc)))))

;;; agent-scheme-host-adapter-fixture-test.el ends here
