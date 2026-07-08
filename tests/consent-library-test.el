;;; consent-library-test.el --- R7RS library/import tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for R7RS `define-library' forms, program-level imports,
;; import-set modifiers, explicit library environments, and exported macros.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-result)

(defun consent-library-test--external (source &optional environment)
  "Evaluate SOURCE and return its stable external value representation."
  (consent-value->external
   (consent-eval-source source environment)))

(defun consent-library-test--stdlib-manifest-external (source)
  "Evaluate SOURCE with stdlib manifest field helpers in scope."
  (consent-library-test--external
   (concat
    "(import (scheme base) (stdlib manifest))
     (define (manifest-field entry name)
       (let ((cell (assq name (cdr entry))))
         (and cell (cadr cell))))
     (define (manifest-subfield entry group name)
       (let ((fields (manifest-field entry group)))
         (let ((cell (and fields (assq name fields))))
           (and cell (cadr cell)))))
     "
    source)))

(defconst consent-library-test--root
  (expand-file-name
   ".."
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Repository root for library fixture tests.")

(defun consent-library-test--manifest-source-file (key)
  "Return the absolute manifest-declared source file for library KEY."
  (let ((entry (consent--library-collection-manifest-entry key)))
    (and entry
         (plist-get entry :source-file)
         (consent--manifest-source-library-file
          (plist-get entry :source-file)
          (plist-get entry :root)))))

(defun consent-library-test--write-manifest-root
    (root collection library value-symbol)
  "Write a manifest ROOT for COLLECTION/LIBRARY returning VALUE-SYMBOL."
  (let* ((manifest-file (expand-file-name "manifest.sld" root))
         (collection-file
          (expand-file-name
           (format "inventory/%s.sld" collection)
           root))
         (source-root
          (format "payload/%s/libraries/" collection))
         (source-file
          (expand-file-name
           (format "%s%s.sld" source-root library)
           root)))
    (make-directory (file-name-directory collection-file) t)
    (make-directory (file-name-directory source-file) t)
    (write-region
     (format
      "(define-library (manifest index)
  (export manifest-index)
  (import (scheme base))
  (begin
    (define manifest-index
      '((manifest-index-entry
         (schema-version 1)
         (kind manifest-collection)
         (name %s)
         (owner project)
         (provider test)
         (collection %s)
         (category %s)
         (manifest-library (%s manifest))
         (manifest-variable %s-manifest)
         (manifest-file \"inventory/%s.sld\")
         (source-root \"%s\")
         (source-kind manifest)
         (api-version internal)
         (source-version runtime)
         (realization manifest)
         (status available)
         (canonical #t))))))
"
      collection collection collection collection collection collection source-root)
     nil
     manifest-file)
    (write-region
     (format
      "(define-library (%s manifest)
  (export %s-manifest)
  (import (scheme base))
  (begin
    (define %s-manifest
      '((manifest-entry
         (schema-version 1)
         (kind library)
         (name (%s %s))
         (owner project)
         (provider test)
         (visibility public)
         (layer %s)
         (source-kind source-library)
         (source (path \"%s.sld\"))
         (api-version (compat 0))
         (source-version unknown)
         (realization portable-source)
         (exports (%s))
         (dependencies ((library (scheme base))))
         (provenance ((origin test-fixture)))
         (status implemented)
         (canonical #t))))))
"
      collection collection collection collection library collection
      library library)
     nil
     collection-file)
    (write-region
     (format
      "(define-library (%s %s)
  (export %s)
  (import (scheme base))
  (begin
    (define (%s) '%s)))
"
      collection library library library value-symbol)
     nil
     source-file)))

(defconst consent-library-test--include-options
  (list :include-directory consent-library-test--root
        :include-paths
        (list (expand-file-name "fixtures/r7rs"
                                consent-library-test--root))
        :file-paths
        (list (expand-file-name "fixtures/r7rs"
                                consent-library-test--root)))
  "Policy options that allow R7RS fixture includes.")

(defun consent-library-test--file-grant-options
    (&optional root paths operations)
  "Return OPTIONS with a first-class file capability grant."
  (let ((root-directory
         (file-name-as-directory
          (expand-file-name (or root consent-library-test--root)))))
    (list
     :include-directory root-directory
     :capability-grants
     (list
      `(capability-grant
        (id fixture-file-grant)
        (domain file)
        (operations ,@(or operations
                          '(metadata read include include-ci load
                                     library-source)))
        (scope (project-root ,root-directory)
               (paths ,(or paths '("fixtures/r7rs")))
               (remote denied)
               (symlinks resolve-within-root))
        (expires never)
        (reason "Allow fixture file capability tests."))))))

(defun consent-library-test--external/options (source options)
  "Evaluate SOURCE with OPTIONS and return its stable external value."
  (consent-value->external
   (consent-eval-source source nil options)))

(defun consent-library-test--audit-strings ()
  "Return recent audit entries as external Scheme-readable strings."
  (mapcar #'consent-result->external
          (consent-audit-recent-entries)))

(defun consent-library-test--audit-entry-matching (&rest snippets)
  "Return the first audit entry string containing all SNIPPETS."
  (cl-find-if
   (lambda (entry)
     (cl-every
      (lambda (snippet)
        (string-match-p (regexp-quote snippet) entry))
      snippets))
   (consent-library-test--audit-strings)))

(defun consent-library-test--write-file (path contents)
  "Write CONTENTS to PATH, creating parent directories as needed."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert contents)))

(defun consent-library-test--write-binary-file (path bytes)
  "Write byte sequence BYTES to PATH, creating parent directories as needed."
  (make-directory (file-name-directory path) t)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (dolist (byte bytes)
      (insert (unibyte-string byte)))
    (write-region (point-min) (point-max) path nil 'silent)))

(defun consent-library-test--read-binary-file (path)
  "Return PATH contents as a list of byte values."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (let (bytes)
      (dotimes (index (buffer-size) (nreverse bytes))
        (push (char-after (1+ index)) bytes)))))

(defun consent-library-test--standard-source-spec (name specs)
  "Return the source library spec named NAME from SPECS."
  (cl-find name specs
           :key (lambda (spec) (plist-get spec :name))
           :test #'equal))

(defun consent-library-test--scheme-string-literal (text)
  "Return TEXT rendered as a Scheme string literal."
  (prin1-to-string text))

(defconst consent-library-test--srfi-180-fixture-directory
  (expand-file-name "fixtures/srfi-180/files" consent-library-test--root)
  "Vendored SRFI 180 JSON fixture corpus directory.")

(defconst consent-library-test--srfi-180-valid-xfails
  nil
  "Valid SRFI 180 fixtures allowed to fail.
Keep this list empty: upstream `y_*.json' files are positive corpus coverage.")

(defconst consent-library-test--srfi-180-valid-stress-fixtures
  '("y_foundationdb_status.json")
  "Large valid SRFI 180 fixtures that run as positive stress coverage.")

(defconst consent-library-test--srfi-180-invalid-xfails
  '(("n_array_comma_after_close.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_array_extra_close.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_object_trailing_comment.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_object_trailing_comment_open.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_object_trailing_comment_slash_open.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_object_trailing_comment_slash_open_incomplete.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_object_with_trailing_garbage.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_string_with_trailing_garbage.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_array_trailing_garbage.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_array_with_extra_array_close.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_close_unopened_array.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_double_array.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_number_with_trailing_garbage.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_object_followed_by_closing_object.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_object_with_trailing_garbage.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_open_array_object.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text.")
    ("n_structure_trailing_#.json"
     . "SRFI 180 json-read consumes one top-level value; this fixture tests trailing text."))
  "Invalid SRFI 180 fixtures excluded from the json-read error corpus.")

(defconst consent-library-test--srfi-180-byte-patterns
  '("invalid[-_]utf8"
    "invalid-utf-8"
    "lone-invalid-utf-8"
    "lone_utf8_continuation"
    "overlong_sequence"
    "truncated-utf-8"
    "UTF-16"
    "utf16"
    "iso_latin_1")
  "Filename patterns for byte-decoding cases beyond textual-port coverage.")

(defun consent-library-test--srfi-180-fixture-names (regexp)
  "Return sorted SRFI 180 fixture names matching REGEXP."
  (sort (directory-files consent-library-test--srfi-180-fixture-directory
                         nil regexp)
        #'string<))

(defun consent-library-test--srfi-180-non-stress-valid-fixtures (names)
  "Return valid fixture NAMES except the large stress corpus fixtures."
  (cl-remove-if
   (lambda (name)
     (member name consent-library-test--srfi-180-valid-stress-fixtures))
   names))

(defun consent-library-test--srfi-180-relative-path (name)
  "Return repository-relative SRFI 180 fixture path for NAME."
  (concat "fixtures/srfi-180/files/" name))

(defun consent-library-test--srfi-180-file-string-literal (name)
  "Return SRFI 180 fixture NAME contents as a Scheme string literal."
  (consent-library-test--scheme-string-literal
   (with-temp-buffer
     (insert-file-contents-literally
      (expand-file-name name consent-library-test--srfi-180-fixture-directory))
     (buffer-string))))

(defun consent-library-test--srfi-180-options ()
  "Return file capability options for reading the SRFI 180 fixture corpus."
  (append
   (consent-library-test--file-grant-options
    consent-library-test--root
    '("fixtures/srfi-180")
    '(metadata read))
   ;; The valid corpus intentionally includes y_foundationdb_status.json. The
   ;; batch ceilings must leave room for that large official fixture while still
   ;; proving JSON reads are budgeted, not unbounded.
   '(:max-steps 12000000
     :max-host-callbacks 2000000)))

(defun consent-library-test--srfi-180-eval (body)
  "Evaluate BODY with SRFI 180 corpus imports and file grants."
  (consent-library-test--external/options
   (concat "(import (scheme base)\n"
           "        (scheme file)\n"
           "        (scheme generator)\n"
           "        (srfi 180))\n"
           body)
   (consent-library-test--srfi-180-options)))

(defun consent-library-test--srfi-180-path-list-literal (names)
  "Return NAMES as a Scheme list literal of fixture-relative paths."
  (concat
   "("
   (mapconcat
    #'consent-library-test--scheme-string-literal
    (mapcar #'consent-library-test--srfi-180-relative-path names)
    " ")
   ")"))

(defun consent-library-test--srfi-180-valid-failures (names)
  "Return Scheme-readable failures for valid fixture NAMES."
  (consent-library-test--srfi-180-eval
   (format
    "(let loop ((paths '%s) (failures '()))
       (if (null? paths)
           (reverse failures)
           (let ((path (car paths)))
             (let ((result
                    (guard (condition
                            (else 'raised))
                      (call-with-input-file path
                        (lambda (port)
                          (json-read port)))
                      'ok)))
               (if (eq? result 'ok)
                   (loop (cdr paths) failures)
                   (loop (cdr paths) (cons (list path result) failures)))))))"
    (consent-library-test--srfi-180-path-list-literal names))))

(defun consent-library-test--srfi-180-invalid-failures (names)
  "Return Scheme-readable failures for deterministic invalid fixture NAMES."
  (consent-library-test--srfi-180-eval
   (format
    "(parameterize ((json-nesting-depth-limit 32))
       (let loop ((paths '%s) (failures '()))
         (if (null? paths)
             (reverse failures)
             (let* ((path (car paths))
                    (result
                     (guard (condition
                             ((json-error? condition) 'json-error)
                             (else 'wrong-condition))
                       (call-with-input-file path
                         (lambda (port)
                           (json-read port)
                           'no-error)))))
               (if (eq? result 'json-error)
                   (loop (cdr paths) failures)
                   (loop (cdr paths) (cons (list path result) failures)))))))"
    (consent-library-test--srfi-180-path-list-literal names))))

(defun consent-library-test--srfi-180-byte-xfail-reason (name)
  "Return byte-decoding xfail reason for fixture NAME, or nil."
  (and (cl-some (lambda (pattern) (string-match-p pattern name))
                consent-library-test--srfi-180-byte-patterns)
       "Fixture depends on byte decoding before JSON parsing; current tests use textual ports."))

(defun consent-library-test--srfi-180-invalid-xfail-reason (name)
  "Return invalid fixture xfail reason for NAME, or nil."
  (or (cdr (assoc name consent-library-test--srfi-180-invalid-xfails))
      (consent-library-test--srfi-180-byte-xfail-reason name)))

(defun consent-library-test--srfi-180-implementation-reason (name)
  "Return explicit implementation-defined classification reason for NAME."
  (cond
   ((string-prefix-p "i_number_" name)
    "Numeric overflow, underflow, or precision is implementation-defined.")
   ((string-prefix-p "i_structure_500_nested_arrays" name)
    "Deep nesting is covered by the explicit json-nesting-depth-limit test.")
   ((string-prefix-p "i_structure_UTF-8_BOM" name)
    "UTF-8 BOM handling is implementation-defined for textual ports.")
   ((or (string-prefix-p "i_string_" name)
        (string-prefix-p "i_object_key_" name))
    "Unicode surrogate and byte-decoding behavior is implementation-defined.")
   (t nil)))

(ert-deftest consent-library-test-imports-scheme-base-into-empty-environment ()
  "Import `(scheme base)' into an otherwise empty program environment."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base))
      (+ 1 2)"
     (consent-make-empty-environment))
    "3")))

(ert-deftest consent-library-test-define-library-import-export ()
  "Define a library and import its exported value into a program."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture math)
        (export answer)
        (import (scheme base))
        (begin
          (define answer 42)))
      (import (consent fixture math))
      answer")
    "42")))

(ert-deftest consent-library-test-import-set-modifiers ()
  "Apply only, except, prefix, and rename import modifiers."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture modifiers)
        (export add sub hidden)
        (import (scheme base))
        (begin
          (define (add x y) (+ x y))
          (define (sub x y) (- x y))
          (define hidden 99)))
      (import (only (consent fixture modifiers) add)
              (except (prefix (consent fixture modifiers) lib-) lib-hidden)
              (rename (consent fixture modifiers) (sub minus)))
      (list (add 1 2)
            (lib-add 3 4)
            (lib-sub 10 6)
            (minus 8 5))")
    "(3 7 4 3)")))

(ert-deftest consent-library-test-export-rename ()
  "Export an internal binding under a different external name."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture export-rename)
        (export (rename internal external))
        (import (scheme base))
        (begin
          (define internal 42)))
      (import (consent fixture export-rename))
      external")
    "42")))

(ert-deftest consent-library-test-emacs-capability-imports-export-bindings ()
  "Import Emacs capability libraries without polluting standard Scheme."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (emacs buffer)
              (emacs frame)
              (emacs process))
      (list (procedure? emacs-current-buffer)
            (procedure? emacs-current-frame)
            (procedure? emacs-process-list))")
    "(#t #t #t)")))

(ert-deftest consent-library-test-conflicting-imports-signal-error ()
  "Reject importing the same local name from different bindings."
  (should-error
   (consent-eval-source
    "(define-library (consent fixture left)
       (export value)
       (import (scheme base))
       (begin (define value 'left)))
     (define-library (consent fixture right)
       (export value)
       (import (scheme base))
       (begin (define value 'right)))
     (import (consent fixture left)
             (consent fixture right))
     value")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-exported-macros-keep-library-scope ()
  "Import an exported syntax-rules macro with definition-scope references."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture syntax)
        (export choose)
        (import (scheme base))
        (begin
          (define default 'library)
          (define-syntax choose
            (syntax-rules ()
              ((choose) default)))))
      (import (scheme base)
              (consent fixture syntax))
      (let ((default 'program))
        (choose))")
    "library")))

(ert-deftest consent-library-test-procedures-keep-private-imported-syntax ()
  "Evaluate library procedures with their defining syntax environment."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture private-syntax)
        (export choose-private)
        (import (scheme base))
        (begin
          (define-syntax choose-private
            (syntax-rules ()
              ((choose-private value fallback)
               (let ((candidate value))
                 (if candidate candidate fallback)))))))
      (define-library (consent fixture private-use)
        (export use-private)
        (import (scheme base)
                (consent fixture private-syntax))
        (begin
          (define (use-private value)
            (choose-private value 'fallback))))
      (import (scheme base)
              (consent fixture private-use))
      (list (use-private 'ok) (use-private #f))")
    "(ok fallback)")))

(ert-deftest consent-library-test-cond-expand-library-declaration ()
  "Expand library-level cond-expand clauses into declarations."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture conditional)
        (cond-expand
          ((library (scheme base))
           (export answer)
           (import (scheme base))
           (begin (define answer 42)))
          (else
           (export answer)
           (begin (define answer 'missing)))))
      (import (consent fixture conditional))
      answer")
    "42")))

(ert-deftest consent-library-test-cond-expand-consent-feature ()
  "Recognize the Consent host feature in library-level cond-expand."
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture conditional-host)
        (cond-expand
          (consent
           (export answer)
           (import (scheme base))
           (begin (define answer 'consent)))
          (else
           (export answer)
           (import (scheme base))
           (begin (define answer 'missing)))))
      (import (consent fixture conditional-host))
      answer")
    "consent")))

(ert-deftest consent-library-test-include-declarations-are-policy-gated ()
  "Keep library declarations that read host files behind a policy gate."
  (should-error
   (consent-eval-source
    "(define-library (consent fixture include)
       (export answer)
       (import (scheme base))
       (include \"fixtures/r7rs/conformance-cases.scm\"))")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-include-reads-policy-allowed-body ()
  "Read library body forms from policy-allowed include files."
  (should
   (equal
    (consent-library-test--external/options
     "(define-library (consent fixture include-body)
        (export answer)
        (import (scheme base))
        (include \"fixtures/r7rs/include-body.scm\"))
      (import (consent fixture include-body))
      answer"
     consent-library-test--include-options)
    "42")))

(ert-deftest consent-library-test-include-ci-folds-policy-allowed-body ()
  "Read include-ci files with fold-case enabled."
  (should
   (equal
    (consent-library-test--external/options
     "(define-library (consent fixture include-ci-body)
        (export mixedanswer)
        (import (scheme base))
        (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
      (import (consent fixture include-ci-body))
      mixedanswer"
     consent-library-test--include-options)
    "42")))

(ert-deftest consent-library-test-include-library-declarations-splice ()
  "Splice policy-allowed library declarations into the current library."
  (should
   (equal
    (consent-library-test--external/options
     "(define-library (consent fixture included-declarations)
        (include-library-declarations
         \"fixtures/r7rs/include-library-declarations.scm\"))
      (import (consent fixture included-declarations))
      answer"
     consent-library-test--include-options)
    "42")))

(ert-deftest consent-library-test-standard-source-libraries-are-file-backed ()
  "Discover source files and exports for portable standard libraries."
  (let ((specs (consent-standard-source-library-specs)))
    (dolist (case '(("(scheme case-lambda)"
                     ("case-lambda")
                     "scheme/consent/case-lambda.sld")
                   ("(scheme lazy)"
                    ("delay" "delay-force" "force" "make-promise"
                     "promise?")
                    "scheme/consent/lazy.sld")))
      (let* ((name (car case))
             (expected-exports (cadr case))
             (expected-source-suffix (caddr case))
             (spec (consent-library-test--standard-source-spec
                    name specs))
             (source-file (plist-get spec :source-file)))
        (should spec)
        (should (equal (plist-get spec :exports) expected-exports))
        (should (string-suffix-p expected-source-suffix source-file))
        (should (file-readable-p source-file))
        (with-temp-buffer
          (insert-file-contents source-file)
          (should
           (string-match-p
            (regexp-quote (format "(define-library %s" name))
            (buffer-string))))))))

(ert-deftest consent-library-test-catalog-helpers-are-private ()
  "Keep manifest catalog helpers out of the public Emacs Lisp namespace."
  (let (public)
    (mapatoms
     (lambda (symbol)
       (when (and (fboundp symbol)
                  (string-prefix-p "consent-library-catalog-"
                                   (symbol-name symbol)))
         (push symbol public))))
    (should-not public)))

(ert-deftest consent-library-test-agent-session-is-source-backed ()
  "Load `(agent session)' from the shared portable source library."
  (let ((source-file
         (consent-library-test--manifest-source-file "(agent session)")))
    (should source-file)
    (should (string-suffix-p "scheme/agent/session.sld" source-file))
    (should (file-readable-p source-file)))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent session))
      (define store (consent-make-session-store))
      (define created
        (session-store-create! store 'named '((id source-alpha))))
      (define snapshot
        (session-store-snapshot! store 'source-alpha '((id source-snap))))
      (define forked
        (session-store-fork! store 'source-alpha '((id source-beta))))
      (list
       (session-datum-id created)
       (session-datum-id (session-store-ref store 'source-alpha))
       (map session-datum-id (session-store-list store))
       (cadr (assq 'status (cdr (session-store-suspend! store 'source-alpha))))
       (cadr (assq 'status (cdr (session-store-resume! store 'source-alpha))))
       (cadr (assq 'id (cdr snapshot)))
       (session-datum-id forked)
       (cadr (assq 'status (cdr (session-store-retire! store 'source-alpha)))))")
    "(source-alpha source-alpha (source-alpha source-beta) suspended active source-snap source-beta retired)")))

(ert-deftest consent-library-test-agent-memory-is-source-backed ()
  "Load `(agent memory)' from the shared portable source library."
  (let ((source-file
         (consent-library-test--manifest-source-file "(agent memory)")))
    (should source-file)
    (should (string-suffix-p "scheme/agent/memory.sld" source-file))
    (should (file-readable-p source-file)))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent memory))
      (define store (consent-make-memory-store))
      (define kept
        (memory-store-put! store
                           'instance
                           'source-alpha
                           '((tags (source fact))
                             (value \"source-backed memory\")
                             (confidence high))))
      (define generated
        (memory-store-add! store
                           'project
                           'note
                           '((tags (project))
                             (value \"generated memory\"))))
      (list
       (memory-record-id kept)
       (memory-record-id
        (memory-store-ref store 'instance 'source-alpha))
       (map memory-record-id (memory-store-by-tag store 'instance 'source))
       (map memory-record-id
            (memory-store-find store 'project \"generated memory\"))
       (memory-record-id generated)
       (memory-store-delete! store 'instance 'source-alpha)
       (memory-store-ref store 'instance 'source-alpha))")
    (concat
     "(source-alpha source-alpha (source-alpha) (m-2) m-2 "
     "(memory (id source-alpha) (scope instance) (key source-alpha) "
     "(kind datum) (memory-class semantic) (tags (source fact)) "
     "(value \"source-backed memory\") (source ()) (confidence high) "
     "(importance 1) (created-at 1) (updated-at 1)) #f)"))))

(ert-deftest consent-library-test-agent-models-openai-is-source-backed ()
  "Load `(agent models openai)' from the shared portable source library."
  (let ((source-file
         (consent-library-test--manifest-source-file
          "(agent models openai)")))
    (should source-file)
    (should (string-suffix-p "scheme/agent/models/openai.sld" source-file))
    (should (file-readable-p source-file)))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent models openai))
      (model-openai-parse-response
       \"{\\\"choices\\\":[{\\\"message\\\":{\\\"content\\\":\\\"source completion\\\"}}]}\")")
    "\"source completion\"")))

(ert-deftest consent-library-test-public-import-and-alias-remain-available ()
  "Keep public and alias imports stable while internal tiers are gated."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent memory) (srfi 16))
      (define store (consent-make-memory-store))
      ((case-lambda
         ((value) value))
       (consent-memory-store? store))")
    "#t")))

(ert-deftest consent-library-test-internal-runtime-import-denied-by-default ()
  "Reject runtime implementation libraries without internal posture."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (consent reader))
            'ok")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote
       "internal library import requires internal-libraries-allowed")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "(consent reader)")
      (error-message-string error)))))

(ert-deftest consent-library-test-agent-primitive-backing-import-denied-by-default ()
  "Reject primitive backing libraries without internal posture."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (agent memory primitive))
            'ok")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote
       "internal library import requires internal-libraries-allowed")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "(agent memory primitive)")
      (error-message-string error)))))

(ert-deftest consent-library-test-agent-primitive-backing-is-not-model-tier ()
  "Classify agent primitive overlays separately from model-provider layers."
  (let ((entry
         (consent--library-collection-manifest-entry
          "(agent memory primitive)"))
        (provider-entry
         (consent--library-collection-manifest-entry
          "(agent models openai)")))
    (should entry)
    (should (eq (plist-get entry :visibility)
                'internal-agent-primitive))
    (should (eq (plist-get entry :layer) 'primitive))
    (should provider-entry)
    (should (eq (plist-get provider-entry :layer) 'provider))
    (dolist (manifest-entry (consent--library-collection-manifest-entries))
      (should-not
       (string-match-p "\\`(agent model\\(\\s-\\|)\\)"
                       (plist-get manifest-entry :name))))))

(ert-deftest consent-library-test-internal-posture-imports-runtime-source ()
  "Allow white-box runtime imports only under explicit internal posture."
  (should
   (equal
    (consent-library-test--external/options
     "(import (consent reader))
      (string=? (consent-datum->external '(alpha beta))
                \"(alpha beta)\")"
     '(:internal-libraries-allowed t))
    "#t")))

(ert-deftest consent-library-test-manifest-implementation-id-routes-primitives ()
  "Use manifest implementation ids rather than library-name namespaces."
  (let* ((context (consent--new-eval-context nil))
         (environment (consent-make-base-environment))
         (entry (list :name "(custom io)"
                      :source-kind 'primitive
                      :implementation-id 'agent-io)))
    (consent--register-manifest-implementation-library
     entry context environment)
    (let ((library
           (gethash "(custom io)"
                    (consent--eval-context-libraries context))))
      (should library)
      (should
       (member "agent-yield"
               (mapcar #'consent--library-binding-name
                       (consent--library-exports library)))))))

(ert-deftest consent-library-test-primitive-manifests-declare-exports ()
  "Require primitive manifest entries to carry explicit export metadata."
  (dolist (entry (cl-remove-if-not
                  (lambda (entry)
                    (eq (plist-get entry :source-kind) 'primitive))
                  (consent--library-collection-manifest-entries)))
    (should (consp (plist-get entry :exports))))
  (should
   (equal
    (plist-get (consent--library-collection-manifest-entry "(agent io)")
               :exports)
    '("agent-yield"
      "agent-log"
      "agent-progress"
      "agent-warn"
      "agent-request")))
  (should
   (member
    "char-alphabetic?"
    (plist-get (consent--library-collection-manifest-entry "(scheme char)")
               :exports))))

(ert-deftest consent-library-test-obsolete-library-dispatchers-are-retired ()
  "Keep repo-owned library surface routing out of hand-curated dispatchers."
  (dolist (symbol '(consent--register-agent-library
                    consent--register-consent-library
                    consent--register-cli-library
                    consent--register-standard-library
                    consent--register-stdlib-library))
    (should-not (fboundp symbol)))
  (dolist (symbol '(consent--standard-source-library-file
                    consent--standard-source-library-source
                    consent--stdlib-source-library-file
                    consent--stdlib-source-library-source
                    consent--agent-source-library-file
                    consent--agent-source-library-source
                    consent--standard-source-library-form
                    consent--standard-source-library-export-names))
    (should-not (fboundp symbol)))
  (should-not (boundp 'consent--cxr-library-names))
  (let* ((entry (consent--library-collection-manifest-entry "(scheme cxr)"))
         (exports (plist-get entry :exports))
         (specs (consent--manifest-exported-primitive-specs entry)))
    (should (equal (mapcar #'car specs) exports))))

(ert-deftest consent-library-test-emacs-capability-keys-follow-manifest ()
  "Derive Emacs capability library keys instead of maintaining a twin list."
  (let ((manifest-keys
         (sort
          (mapcar
           (lambda (entry)
             (plist-get entry :name))
           (cl-remove-if-not
            (lambda (entry)
              (eq (plist-get entry :implementation-id) 'emacs-capability))
            (consent--library-collection-manifest-entries)))
          #'string<))
        (runtime-keys
         (sort (copy-sequence (consent-emacs-capability-library-keys))
               #'string<)))
    (should-not (boundp 'consent--emacs-capability-library-keys))
    (should (equal runtime-keys manifest-keys))))

(ert-deftest consent-library-test-built-in-categories-come-from-manifests ()
  "Keep catalog family metadata in manifests, not namespace-prefix code."
  (dolist (entry (consent--library-collection-manifest-entries))
    (should (plist-get entry :category)))
  (should (eq (plist-get
               (consent--library-collection-manifest-entry "(scheme char)")
               :category)
              'standard))
  (should (eq (plist-get
               (consent--library-collection-manifest-entry "(consent reader)")
               :category)
              'consent))
  (should (eq (plist-get
               (consent--library-collection-manifest-entry "(srfi 1)")
               :category)
              'stdlib))
  (should (eq (plist-get
               (consent--library-collection-manifest-entry "(manifest index)")
               :category)
              'manifest)))

(ert-deftest consent-library-test-stdlib-manifests-name-upstream-source-url ()
  "Use upstream-source-url for imported provenance metadata."
  (dolist (spec (consent--library-collection-manifest-specs))
    (dolist (entry (consent--proper-list-elements
                    (consent--collection-manifest-library-value spec)
                    "collection manifest entries"))
      (should-not
       (consent--collection-manifest-field entry "source-url" nil))))
  (let (upstream-urls)
    (dolist (entry (consent--proper-list-elements
                    (consent--collection-manifest-library-value
                     (cl-find-if
                      (lambda (spec)
                        (eq (plist-get spec :collection) 'stdlib))
                      (consent--library-collection-manifest-specs)))
                    "stdlib manifest entries"))
      (let ((url (consent--collection-manifest-field
                  entry "source-url" nil)))
        (should-not url))
      (let* ((provenance
              (consent--collection-manifest-field entry "provenance" nil))
             (url
              (and provenance
                   (consent--library-catalog-manifest-field
                    provenance "upstream-source-url" nil))))
        (when url
          (push url upstream-urls))))
    (should upstream-urls)
    (should
     (member "https://github.com/scheme-requests-for-implementation/srfi-180"
             upstream-urls))))

(ert-deftest consent-library-test-built-in-manifests-declare-owned-exports ()
  "Require owned libraries to spell exports while pure aliases may inherit."
  (let ((missing (list 'missing-exports))
        omitted-pure-alias)
    (dolist (spec (consent--library-collection-manifest-specs))
      (dolist (entry (consent--proper-list-elements
                      (consent--collection-manifest-library-value spec)
                      "collection manifest entries"))
        (let* ((library
                (consent--library-name-key
                 (consent--collection-manifest-field entry "name" nil)))
               (target
                (consent--collection-manifest-target
                 (consent--collection-manifest-field entry "target" nil)))
               (exports
                (consent--collection-manifest-field
                 entry "exports" missing)))
          (if (eq exports missing)
              (if target
                  (setq omitted-pure-alias t)
                (ert-fail
                 (format "owned manifest entry lacks exports: %s" library)))
            (should (listp (consent--proper-list-elements
                            exports
                            (format "exports for %s" library))))))))
    (should omitted-pure-alias)))

(ert-deftest consent-library-test-pure-alias-manifest-inherits-target-exports ()
  "Treat a pure alias without manifest exports as the target's full surface."
  (let ((entry
         (consent--library-collection-manifest-entry "(consent json)")))
    (should (equal (plist-get entry :target) "(stdlib json)"))
    (should-not (plist-get entry :exports))
    (should (member "json-write"
                    (consent--library-catalog-export-names
                     "(consent json)")))
    (should (equal (consent--library-catalog-export-names
                    "(consent json)")
                   (consent--library-catalog-export-names
                    "(stdlib json)")))))

(ert-deftest consent-library-test-built-in-manifests-use-shared-schema ()
  "Read built-in collection manifests through the shared manifest schema."
  (let ((task (consent--library-collection-manifest-entry "(agent task)"))
        (primitive
         (consent--library-collection-manifest-entry
          "(agent memory primitive)"))
        (alias (consent--library-collection-manifest-entry "(consent json)"))
        (index (consent--library-collection-manifest-entry "(manifest index)")))
    (should (= (plist-get task :schema-version) 1))
    (should (eq (plist-get task :kind) 'library))
    (should (eq (plist-get task :owner) 'agent))
    (should (eq (plist-get task :provider) 'repo-source))
    (should (eq (plist-get task :canonical) t))
    (should (equal (consent-datum->external (plist-get task :source))
                   "(path \"agent/task.sld\")"))
    (should (equal (consent-datum->external (plist-get task :api-version))
                   "(compat 0)"))
    (should (eq (plist-get task :source-version) 'unknown))
    (should (eq (plist-get task :realization) 'portable-source))

    (should (eq (plist-get primitive :kind) 'primitive-library))
    (should (eq (plist-get primitive :source-version) 'runtime))
    (should (eq (plist-get primitive :realization) 'host-primitive))
    (should (eq (plist-get primitive :canonical) t))

    (should (eq (plist-get alias :kind) 'library-alias))
    (should-not (plist-get alias :canonical))
    (should (equal (consent-datum->external (plist-get alias :api-version))
                   "(inherits (stdlib json))"))
    (should (eq (plist-get alias :realization) 'alias))

    (should (= (plist-get index :schema-version) 1))
    (should (eq (plist-get index :kind) 'library))
    (should (equal (consent-datum->external (plist-get index :source))
                   "(path \"manifest.sld\")"))))

(ert-deftest consent-library-test-catalog-accepts-shared-manifest-entry ()
  "Accept tagged manifest-entry records in ad-hoc catalogs."
  (unwind-protect
      (progn
        (consent--library-catalog-add-manifest
         'schema-fixture
         (consent-read
          "(library-catalog
             (manifest-entry
              (schema-version 1)
              (kind library)
              (name (project schema))
              (owner project)
              (provider repo-source)
              (visibility public)
              (layer package)
              (source-kind source-library)
              (source (path \"project/schema.sld\"))
              (api-version (compat 2))
              (source-version unknown)
              (realization portable-source)
              (exports (schema-run))
              (dependencies ((library (scheme base))))
              (documentation ((summary \"Project schema.\")))
              (provenance ((origin project)))
              (status experimental)
              (canonical #t)
              (future-field ignored))
             (manifest-entry
              (schema-version 1)
              (kind library)
              (name (agent model session))
              (owner agent-domain)
              (provider repo-source)
              (visibility internal-agent-model)
              (layer model)
              (source-kind source-library)
              (source (path \"agent/model/session.sld\"))
              (api-version internal)
              (source-version unknown)
              (realization portable-source)
              (status internal)
              (canonical #t))
             (manifest-index-entry
              (schema-version 1)
              (kind library-alias)
              (name (project schema alias))
              (target (project schema))
              (derived-from schema-fixture)
              (visibility public)
              (layer alias)
              (source-kind alias)
              (api-version (inherits (project schema)))
              (canonical #f)))"))
        (let ((entry
               (consent--library-catalog-lookup
                (consent-read "(project schema)")))
              (model
               (consent--library-catalog-lookup
                (consent-read "(agent model session)")))
              (alias
               (consent--library-catalog-lookup
                (consent-read "(project schema alias)"))))
          (should (= (plist-get entry :schema-version) 1))
          (should (eq (plist-get entry :kind) 'library))
          (should (eq (plist-get entry :owner) 'project))
          (should (eq (plist-get entry :provider) 'repo-source))
          (should (equal (plist-get entry :source-file)
                         "project/schema.sld"))
          (should (equal (consent-datum->external
                          (plist-get entry :api-version))
                         "(compat 2)"))
          (should (equal (plist-get entry :dependencies)
                         '("(scheme base)")))
          (should (equal (plist-get entry :summary) "Project schema."))
          (should (eq (plist-get entry :canonical) t))
          (should (eq (plist-get model :owner) 'agent-domain))
          (should (eq (plist-get model :visibility) 'internal-agent-model))
          (should (eq (plist-get model :layer) 'model))
          (should (eq (plist-get model :api-version) 'internal))
          (should (eq (plist-get model :source-version) 'unknown))
          (should (eq (plist-get alias :kind) 'library-alias))
          (should-not (plist-get alias :canonical))
          (should (equal (plist-get alias :target) "(project schema)"))))
    (consent--library-catalog-remove-manifest 'schema-fixture)))

(ert-deftest consent-library-test-load-light-avoids-agent-implementation-requires ()
  "Keep manifest aggregation from requiring agent implementations at module load."
  (let ((source
         (with-temp-buffer
           (insert-file-contents
            (expand-file-name "lisp/consent-library.el"
                              consent-library-test--root))
           (buffer-string))))
    (dolist (feature '("consent-agent-io" "consent-approval"
                       "consent-context" "consent-debugger"
                       "consent-helper" "consent-job"
                       "consent-memory" "consent-models"
                       "consent-plan" "consent-redaction"
                       "consent-reflect" "consent-session"
                       "consent-test" "consent-transcript"))
      (should-not
       (string-match-p
        (format "^(require '%s)" (regexp-quote feature))
        source)))))

(ert-deftest consent-library-test-top-level-manifest-is-root-manifest ()
  "Keep the aggregate manifest at the manifest root inside the graph."
  (let ((spec
         (cl-find-if
          (lambda (spec)
            (eq (plist-get spec :collection) 'manifest))
          (consent--library-collection-manifest-specs))))
    (should spec)
    (should (equal (plist-get spec :key) "(manifest index)"))
    (should (equal (plist-get spec :manifest-file) "manifest.sld"))
    (should (equal (plist-get spec :source-root) ""))
    (should (equal (plist-get spec :variable) "manifest-index-manifest"))
    (let ((entry
           (consent--library-collection-manifest-entry
            "(manifest index)")))
      (should entry)
      (should (eq (plist-get entry :source-kind) 'portable-source))
      (should (equal (plist-get entry :source-file) "manifest.sld"))
      (should (equal (plist-get entry :exports)
                     '("manifest-index" "manifest-index-ref"))))))

(ert-deftest consent-library-test-root-manifest-drives-collections ()
  "Bootstrap collection discovery from system/user root `manifest.sld' files."
  (let ((system-root (make-temp-file "consent-system-manifest-seed-" t))
        (user-root (make-temp-file "consent-user-manifest-seed-" t))
        (ignored-root (make-temp-file "consent-empty-manifest-seed-" t)))
    (unwind-protect
        (progn
          (consent-library-test--write-manifest-root
           system-root
           'system
           'tool
           'system-tool)
          (consent-library-test--write-manifest-root
           user-root
           'user
           'tool
           'user-tool)
          (let ((consent-library-system-path
                 (list system-root ignored-root))
                (consent-library-user-path
                 (list user-root))
                (consent--library-collection-manifest-cache nil))
            (let* ((specs (consent--library-collection-manifest-specs))
                   (entries
                    (consent--library-collection-manifest-entries))
                   (system-spec (car specs))
                   (user-spec (cadr specs))
                   (system-entry
                    (consent--library-collection-manifest-entry
                     "(system tool)"))
                   (user-entry
                    (consent--library-collection-manifest-entry
                     "(user tool)"))
                   (context (consent--new-eval-context nil))
                   (environment (consent-make-base-environment)))
              (should (= (length specs) 2))
              (should (eq (plist-get system-spec :collection) 'system))
              (should (eq (plist-get user-spec :collection) 'user))
              (should (equal (plist-get system-spec :root-kind) 'system))
              (should (equal (plist-get user-spec :root-kind) 'user))
              (should (equal (plist-get system-spec :key)
                             "(system manifest)"))
              (should (equal (plist-get user-spec :key)
                             "(user manifest)"))
              (should (equal (plist-get system-spec :manifest-file)
                             "inventory/system.sld"))
              (should (equal (plist-get user-spec :manifest-file)
                             "inventory/user.sld"))
              (should (equal (plist-get system-spec :source-root)
                             "payload/system/libraries/"))
              (should (equal (plist-get user-spec :source-root)
                             "payload/user/libraries/"))
              (should (= (length entries) 2))
              (should (equal (plist-get system-entry :source-file)
                             "payload/system/libraries/tool.sld"))
              (should (equal (plist-get user-entry :source-file)
                             "payload/user/libraries/tool.sld"))
              (consent--register-scheme-base-library context environment)
              (consent--register-manifest-source-library
               system-entry
               context
               environment)
              (consent--register-manifest-source-library
               user-entry
               context
               environment)
              (should (gethash "(system tool)"
                               (consent--eval-context-libraries
                                context)))
              (should (gethash "(user tool)"
                               (consent--eval-context-libraries
                                context))))))
      (delete-directory system-root t)
      (delete-directory user-root t)
      (delete-directory ignored-root t))))

(ert-deftest consent-library-test-source-manifest-exports-filter-library ()
  "Let source-library manifest exports narrow the source definition."
  (let* ((context (consent--new-eval-context nil))
         (environment (consent-make-base-environment))
         (entry (list :name "(scheme lazy)"
                      :source-kind 'portable-source
                      :source-file "consent/lazy.sld"
                      :exports '("force"))))
    (consent--register-manifest-source-library entry context environment)
    (let* ((library (gethash "(scheme lazy)"
                             (consent--eval-context-libraries context)))
           (exports (mapcar #'consent--library-binding-name
                            (consent--library-exports library))))
      (should (equal exports '("force"))))))

(ert-deftest consent-library-test-agent-generated-source-is-source-backed ()
  "Load `(agent generated-source)' from the shared portable source library."
  (let ((source-file
         (consent-library-test--manifest-source-file
          "(agent generated-source)")))
    (should source-file)
    (should (string-suffix-p
             "scheme/agent/generated-source.sld"
             source-file))
    (should (file-readable-p source-file)))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent generated-source))
      (generated-source-candidate-status
       (generated-source-candidate \"(define answer 42)\\nanswer\\n\"))")
    "ready")))

(ert-deftest consent-library-test-source-backed-calls-use-adapter-budget ()
  "Source-backed adapter calls use their own evaluation budget."
  ;; Prime the source environment so the assertion only covers procedure calls.
  (consent--source-library-procedure
   "(agent models openai)"
   "model-openai-parse-response")
  (let ((consent-eval-maximum-steps 1))
    (should
     (equal
      (consent-result->external
       (consent--source-library-call
        "(agent models openai)"
        "model-openai-parse-response"
        "{\"choices\":[{\"message\":{\"content\":\"budgeted source\"}}]}"))
      "\"budgeted source\""))))

(ert-deftest consent-library-test-standard-case-lambda-import ()
  "Import `(scheme case-lambda)' through the library registry."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme case-lambda))
      ((case-lambda
         ((x) x)
         ((x y) (+ x y)))
       1 2)")
    "3"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme case-lambda))
      (list
       ((case-lambda
          ((x) x)
          ((x y . rest) (list x y rest)))
        1 2 3 4)
       ((case-lambda
          (all all))
        'a 'b))")
    "((1 2 (3 4)) (a b))")))

(ert-deftest consent-library-test-srfi-16-case-lambda-alias-import ()
  "Import SRFI 16 aliases over the R7RS case-lambda library."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 16))
      (define (describe . args)
        (apply
         (case-lambda
          (() 'zero)
          ((x) (list 'one x))
          ((x . rest) (list 'many x rest)))
         args))
      (list (describe) (describe 'a) (describe 'a 'b 'c))")
    "(zero (one a) (many a (b c)))"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-16))
      ((case-lambda
         ((x y) (+ x y)))
       2 5)")
    "7")))

(ert-deftest consent-library-test-srfi-16-case-lambda-no-matching-clause ()
  "Report an error when an SRFI 16 case-lambda has no matching arity."
  (should-error
   (consent-library-test--external
    "(import (scheme base) (srfi 16))
     ((case-lambda
        ((x) x)))")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-srfi-16-missing-export-diagnostic ()
  "Report missing SRFI 16 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 16) missing-case-lambda))
            missing-case-lambda")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-case-lambda")
      (error-message-string error)))))

(ert-deftest consent-library-test-srfi-2-and-let-star-behavior ()
  "Import SRFI 2 aliases and exercise `and-let*' behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 2))
      (let ((events '()))
        (define (record tag value)
          (set! events (cons tag events))
          value)
        (list
         (and-let* () 'empty)
         (and-let* () 1 2)
         (and-let* ((x (record 'x '(a b)))
                    ((pair? x))
                    (tail (cdr x))
                    tail)
           (list (car x) tail (reverse events)))
         (and-let* ((flag #f)
                    (never (record 'never #t)))
           'unreached)
         (and-let* ((x 1) (x (+ x 1)) (x (+ x 1)))
           x)))")
    "(empty 2 (a (b) (x)) #f 3)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-2))
      (and-let* (((positive? 3)) (x 4)) x)")
    "4"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib and-let-star))
      (and-let* ((x 'primary)) x)")
    "primary")))

(ert-deftest consent-library-test-srfi-2-missing-export-diagnostic ()
  "Report missing SRFI 2 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 2) missing-and-let-star))
            missing-and-let-star")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-and-let-star")
      (error-message-string error)))))

(ert-deftest consent-library-test-srfi-8-receive-behavior ()
  "Import SRFI 8 aliases and exercise `receive' behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 8))
      (list
       (receive (x y) (values 2 5) (+ x y))
       (receive all (values 'a 'b 'c) all)
       (receive (head . tail) (values 'first 'second 'third)
         (list head tail)))")
    "(7 (a b c) (first (second third)))"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-8))
      (receive (x y) (values 4 6) (* x y))")
    "24"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib receive))
      (receive (x y) (values 'left 'right)
        (list y x))")
    "(right left)")))

(ert-deftest consent-library-test-srfi-8-missing-export-diagnostic ()
  "Report missing SRFI 8 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 8) missing-receive))
            missing-receive")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-receive")
      (error-message-string error)))))

(ert-deftest consent-library-test-srfi-145-assume-behavior ()
  "Import SRFI 145 aliases and exercise `assume' behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 145))
      (let ((events '()))
        (define (record tag value)
          (set! events (cons tag events))
          value)
        (list
         (assume (record 'truth '(a b))
                 (record 'message 'unreached))
         (assume 0 \"zero is true\")
         events))")
    "((a b) 0 (truth))"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-145))
      (assume 'portable-alias)")
    "portable-alias"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib assume))
      (assume '(stdlib primary) \"primary import\")")
    "(stdlib primary)")))

(ert-deftest consent-library-test-srfi-145-false-assumption-errors ()
  "Report a false SRFI 145 assumption as an invalid path error."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base) (srfi 145))
            (assume #f \"expected true\" 'payload)")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "invalid assumption")
      (error-message-string error)))))

(ert-deftest consent-library-test-srfi-145-missing-export-diagnostic ()
  "Report missing SRFI 145 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 145) missing-assume))
            missing-assume")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-assume")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-8 ()
  "Expose SRFI 8 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib receive)))
            (alias (stdlib-manifest-ref '(srfi 8)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-8))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib receive))
             (equal? (manifest-field entry 'status) 'built-in-shim)
             (equal? (manifest-field entry 'source) '(path \"receive.sld\"))
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"Apache-2.0\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #f)
             (equal? (manifest-field entry 'aliases)
                     '((srfi 8) (srfi srfi-8)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))))
             (equal? (manifest-field alias 'target) '(stdlib receive))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib receive))))")
    "#t")))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-2 ()
  "Expose SRFI 2 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib and-let-star)))
            (alias (stdlib-manifest-ref '(srfi 2)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-2))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib and-let-star))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (equal? (manifest-field entry 'aliases)
                     '((srfi 2) (srfi srfi-2)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))))
             (equal? (manifest-field alias 'target) '(stdlib and-let-star))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib and-let-star))))")
    "#t")))

(ert-deftest consent-library-test-srfi-158-imports-and-uses-generators ()
  "Import SRFI 158 aliases and exercise representative generator behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme generator))
      (list (generator->list (gmap - (make-range-generator 0 3)))
            (generator->list
             (gappend (generator 'a 'b)
                      (list->generator '(c d))))
            (let ((acc (list-accumulator)))
              (acc 'x)
              (acc 'y)
              (acc (eof-object))))")
    "((0 -1 -2) (a b c d) (x y))"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 158))
      (generator->list
       (gselect (list->generator '(a b c d e))
                (list->generator '(#t #f #t #f #t))))")
    "(a c e)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-158))
      (let ((acc (sum-accumulator)))
        (acc 1)
        (acc 2)
        (acc (eof-object)))")
    "3")))

(ert-deftest consent-library-test-srfi-158-missing-export-diagnostic ()
  "Report missing SRFI 158 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 158) missing-generator))
            missing-generator")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-generator")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-158 ()
  "Expose SRFI 158 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib generator)))
            (scheme-alias (stdlib-manifest-ref '(scheme generator)))
            (alias (stdlib-manifest-ref '(srfi 158)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-158))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib generator))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (equal? (manifest-field entry 'aliases)
                     '((scheme generator) (srfi 158) (srfi srfi-158)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme case-lambda))))
             (equal? (manifest-field scheme-alias 'target)
                     '(stdlib generator))
             (equal? (manifest-field alias 'target) '(stdlib generator))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib generator))))")
    "#t")))

(ert-deftest consent-library-test-srfi-180-imports-and-round-trips-json ()
  "Import `(srfi 180)' through the library registry and use JSON."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 180))
      (let ((out (open-output-string)))
        (json-write '((name . \"Ada\") (scores . #(1 #t null))) out)
        (let* ((datum (json-read (open-input-string (get-output-string out))))
               (scores (cdr (assq 'scores datum))))
          (list (cdr (assq 'name datum))
                (vector-ref scores 0)
                (vector-ref scores 1)
                (json-null? (vector-ref scores 2)))))")
    "(\"Ada\" 1 #t #t)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-180))
      (json-null? (json-read (open-input-string \"null\")))")
    "#t"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib json))
      (json-null? (json-read (open-input-string \"null\")))")
    "#t"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (consent json))
      (json-null? (json-read (open-input-string \"null\")))")
    "#t")))

(ert-deftest consent-library-test-json-read-subset-filters-exports ()
  "Import the read-side JSON facade without the write-side API."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib json read))
      (json-null? (json-read (open-input-string \"null\")))")
    "#t"))
  (should-error
   (consent-library-test--external
    "(import (scheme base)
             (only (stdlib json read) json-write))
     json-write")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-srfi-180-rejects-non-json-number ()
  "Reject Scheme numbers that have no JSON number spelling."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 180))
      (guard (condition
              ((json-error? condition) #t)
              (else 'wrong-condition))
        (json-write '((half . 1/2)) (open-output-string))
        'no-error)")
    "#t")))

(ert-deftest consent-library-test-srfi-180-character-limit ()
  "Enforce the SRFI 180 character limit parameter while reading JSON."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 180))
      (guard (condition
              ((json-error? condition) #t)
              (else 'wrong-condition))
        (parameterize ((json-number-of-character-limit 4))
          (json-read (open-input-string \"[1,2,3]\")))
        'no-error)")
    "#t")))

(ert-deftest consent-library-test-stdlib-manifest-documents-json ()
  "Expose stdlib JSON support status through a Scheme-readable manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib json))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib json))
             (equal? (manifest-field entry 'status)
                     'direct-portable-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-field entry 'aliases)
                     '((consent json) (srfi 180) (srfi srfi-180)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (stdlib and-let-star))))
             (equal? (manifest-subfield entry 'verification 'test-status)
                     '(import-resolution representative-read-write
                       emacs-json-oracle portable-host-suite
                       imported-reference-corpus json-lines
                       json-text-sequences))))")
    "#t")))

(ert-deftest consent-library-test-srfi-180-emacs-json-oracle ()
  "Cross-check portable SRFI 180 behavior against Emacs json.el."
  (let* ((json-array-type 'vector)
         (json-object-type 'alist)
         (json-key-type 'symbol)
         (json-false :json-false)
         (json-null :json-null)
         (oracle-json
          (json-encode
           `((name . "Ada")
             (scores . [1 t :json-null])
             (nested . ((ok . ,json-false)))))))
    (should
     (equal
      (consent-library-test--external
       (format
        "(import (scheme base) (srfi 180))
         (let* ((datum (json-read (open-input-string %s)))
                (scores (cdr (assq 'scores datum)))
                (nested (cdr (assq 'nested datum))))
           (list (cdr (assq 'name datum))
                 (vector-ref scores 0)
                 (vector-ref scores 1)
                 (json-null? (vector-ref scores 2))
                 (cdr (assq 'ok nested))))"
        (consent-library-test--scheme-string-literal oracle-json)))
      "(\"Ada\" 1 #t #t #f)"))
    (let* ((portable-json
            (consent-eval-source
             "(import (scheme base) (srfi 180))
              (let ((out (open-output-string)))
                (json-write
                 '((name . \"Ada\")
                   (scores . #(1 #t null))
                   (nested . ((ok . #f))))
                 out)
                (get-output-string out))"))
           (parsed (let ((json-array-type 'vector)
                         (json-object-type 'alist)
                         (json-key-type 'symbol)
                         (json-false :json-false)
                         (json-null :json-null))
                     (json-read-from-string portable-json))))
      (should (equal (alist-get 'name parsed) "Ada"))
      (should (equal (aref (alist-get 'scores parsed) 0) 1))
      (should (equal (aref (alist-get 'scores parsed) 1) t))
      (should (eq (aref (alist-get 'scores parsed) 2) :json-null))
      (should (eq (alist-get 'ok (alist-get 'nested parsed)) :json-false)))))

(ert-deftest consent-library-test-srfi-180-reference-corpus-shape ()
  "Keep the pinned SRFI 180 fixture corpus visible to the test harness."
  (let ((valid (consent-library-test--srfi-180-fixture-names "\\`y_.*\\.json\\'"))
        (invalid (consent-library-test--srfi-180-fixture-names "\\`n_.*\\.json\\'"))
        (implementation
         (consent-library-test--srfi-180-fixture-names "\\`i_.*\\.json\\'")))
    (should (= (length valid) 97))
    (should (= (length invalid) 191))
    (should (= (length implementation) 35))
    (should (member "y_foundationdb_status.json" valid))
    (dolist (name consent-library-test--srfi-180-valid-stress-fixtures)
      (should (member name valid)))
    (dolist (name implementation)
      (should (consent-library-test--srfi-180-implementation-reason name)))
    (dolist (entry consent-library-test--srfi-180-valid-xfails)
      (should (member (car entry) valid))
      (should (stringp (cdr entry))))
    (should-not
     (assoc "y_foundationdb_status.json"
            consent-library-test--srfi-180-valid-xfails))
    (dolist (entry consent-library-test--srfi-180-invalid-xfails)
      (should (member (car entry) invalid))
      (should (stringp (cdr entry))))))

(ert-deftest consent-library-test-srfi-180-reference-valid-corpus ()
  "Parse non-stress valid SRFI 180 JSON fixtures."
  (let* ((valid (consent-library-test--srfi-180-fixture-names "\\`y_.*\\.json\\'"))
         (deterministic
          (consent-library-test--srfi-180-non-stress-valid-fixtures
           (cl-remove-if (lambda (name)
                           (assoc name consent-library-test--srfi-180-valid-xfails))
                         valid))))
    (should-not (member "y_foundationdb_status.json" deterministic))
    (should (equal (consent-library-test--srfi-180-valid-failures deterministic)
                   "()"))))

(ert-deftest consent-library-test-srfi-180-reference-valid-stress-corpus ()
  "Parse large valid SRFI 180 JSON stress fixtures."
  (should
   (equal
    (consent-library-test--srfi-180-valid-failures
     consent-library-test--srfi-180-valid-stress-fixtures)
    "()")))

(ert-deftest consent-library-test-srfi-180-reference-invalid-corpus ()
  "Require deterministic invalid SRFI 180 JSON fixtures to raise json-error?."
  (let* ((invalid (consent-library-test--srfi-180-fixture-names "\\`n_.*\\.json\\'"))
         (deterministic
          (cl-remove-if #'consent-library-test--srfi-180-invalid-xfail-reason
                        invalid)))
    (should (> (length deterministic) 120))
    (should (equal (consent-library-test--srfi-180-invalid-failures deterministic)
                   "()"))))

(ert-deftest consent-library-test-srfi-180-reference-invalid-classification ()
  "Record explicit reasons for invalid SRFI 180 fixtures outside text coverage."
  (let* ((invalid (consent-library-test--srfi-180-fixture-names "\\`n_.*\\.json\\'"))
         (xfails
          (cl-loop for name in invalid
                   for reason = (consent-library-test--srfi-180-invalid-xfail-reason
                                 name)
                   when reason
                   collect (list name reason))))
    (should (> (length xfails) 20))
    (dolist (xfail xfails)
      (should (stringp (cadr xfail))))))

(ert-deftest consent-library-test-srfi-180-reference-json-lines ()
  "Read vendored JSON Lines samples through the local SRFI 180 facade."
  (dolist (name '("sample-crlf-line-separators.jsonl"
                  "sample-no-eol-at-eof.jsonl"
                  "sample.jsonl"))
    (should
     (equal
      (consent-library-test--srfi-180-eval
       (format
        "(let ((items (generator->list
                       (json-lines-read (open-input-string %s)))))
           (list (length items)
                 (cdr (assq 'a (car items)))
                 (cdr (assq 'b (cadr items)))))"
        (consent-library-test--srfi-180-file-string-literal name)))
      "(2 1 2)"))))

(ert-deftest consent-library-test-srfi-180-reference-json-sequences ()
  "Read vendored JSON Text Sequences samples through local SRFI 180 APIs."
  (should
   (equal
    (consent-library-test--srfi-180-eval
     (format
      "(define (last-item items)
         (if (null? (cdr items)) (car items) (last-item (cdr items))))
       (let ((items (generator->list
                     (json-sequence-read (open-input-string %s)))))
         (list (length items)
               (cdr (assq 'count (car items)))
               (cdr (assq 'count (last-item items)))))"
      (consent-library-test--srfi-180-file-string-literal
       "json-sequence.log")))
    "(10 0 9)"))
  (should
   (equal
    (consent-library-test--srfi-180-eval
     (format
      "(guard (condition
               ((json-error? condition) 'json-error)
               (else 'wrong-condition))
         (generator->list (json-sequence-read (open-input-string %s)))
         'no-error)"
      (consent-library-test--srfi-180-file-string-literal
       "json-sequence-with-one-broken-json.log")))
    "json-error")))

(ert-deftest consent-library-test-srfi-1-list-library-behavior ()
  "Import primary `(scheme list)' and exercise representative SRFI 1 behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (scheme list))
      (call-with-values
       (lambda ()
         (partition even? '(1 2 3 4 5)))
       (lambda (even odd)
         (list (iota 4)
               (list-tabulate 3 (lambda (n) (* n n)))
               (call-with-values
                (lambda () (split-at '(a b c d) 2))
                list)
               (filter even? '(1 2 3 4))
               (map + '(1 2 3) '(10 20 30))
               (fold + 0 '(1 2 3 4))
               (find-tail even? '(1 3 4 6))
               (any even? '(1 3 5 6))
               (every positive? '(1 2 3))
               (list-index even? '(1 3 4 6))
               (find-tail (lambda (name) (string=? name \"bee\"))
                          '(\"ant\" \"bee\"))
               even
               odd
               (lset-union = '(1 2) '(2 3 4)))))")
    "((0 1 2 3) (0 1 4) ((a b) (c d)) (2 4) (11 22 33) 10 (4 6) #t #t 2 (\"bee\") (2 4) (1 3 5) (4 3 1 2))")))

(ert-deftest consent-library-test-srfi-1-alias-import ()
  "Import SRFI 1 through its secondary `(srfi 1)' alias."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (srfi 1))
      (append-map (lambda (x) (list x (- x))) '(1 2 3))")
    "(1 -1 2 -2 3 -3)")))

(ert-deftest consent-library-test-srfi-1-portable-alias-import ()
  "Import SRFI 1 through its portable `(srfi srfi-1)' alias."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-1))
      (drop-right '(a b c d) 2)")
    "(a b)")))

(ert-deftest consent-library-test-srfi-1-missing-export-diagnostic ()
  "Report missing SRFI 1 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 1) missing-list-helper))
            missing-list-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-list-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-1 ()
  "Expose SRFI 1 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib list)))
            (scheme-alias (stdlib-manifest-ref '(scheme list)))
            (alias (stdlib-manifest-ref '(srfi 1)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-1))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib list))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (equal? (manifest-field entry 'aliases)
                     '((scheme list) (srfi 1) (srfi srfi-1)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base)) (library (scheme cxr))))
             (equal? (manifest-field scheme-alias 'target) '(stdlib list))
             (equal? (manifest-field alias 'target) '(stdlib list))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib list))))")
    "#t")))

(ert-deftest consent-library-test-srfi-128-comparator-behavior ()
  "Import primary `(stdlib comparator)' and exercise SRFI 128 behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib comparator))
      (let* ((number-comparator (make-comparator real? = < number-hash))
             (list-comparator
              (make-list-comparator number-comparator list? null? car cdr))
             (vector-comparator
              (make-vector-comparator
               number-comparator vector? vector-length vector-ref)))
        (list (comparator? number-comparator)
              (comparator-ordered? number-comparator)
              (comparator-hashable? number-comparator)
              (comparator-test-type number-comparator 3)
              (=? number-comparator 3 3 3)
              (<? number-comparator 1 2 3)
              (>? number-comparator 3 2 1)
              (<=? number-comparator 1 1 2)
              (>=? number-comparator 3 3 2)
              (comparator-if<=> number-comparator 1 2 'less 'same 'greater)
              (=? list-comparator '(1 2) '(1 2))
              (<? list-comparator '(1 2) '(1 3))
              (=? vector-comparator '#(1 2) '#(1 2))
              (<? vector-comparator '#(1 2) '#(1 2 0))
              (exact-integer? (comparator-hash number-comparator 42))
              (< (hash-salt) (hash-bound))))")
    "(#t #t #t #t #t #t #t #t #t less #t #t #t #t #t #t)")))

(ert-deftest consent-library-test-srfi-128-alias-import ()
  "Import SRFI 128 through its secondary `(srfi 128)' alias."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 128))
      (let ((string-comparator
             (make-comparator string? string=? string<? string-hash)))
        (list (<? string-comparator \"ant\" \"bee\")
              (=? string-comparator \"same\" \"same\")))")
    "(#t #t)")))

(ert-deftest consent-library-test-srfi-128-portable-alias-import ()
  "Import SRFI 128 through its portable `(srfi srfi-128)' alias."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-128))
      (let ((string-comparator
             (make-comparator string? string=? string<? string-hash)))
        (list (<? string-comparator \"ant\" \"bee\")
              (=? string-comparator \"same\" \"same\")))")
    "(#t #t)")))

(ert-deftest consent-library-test-srfi-128-missing-export-diagnostic ()
  "Report missing SRFI 128 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (scheme comparator) missing-comparator))
            missing-comparator")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-comparator")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-comparator ()
  "Expose stdlib comparator support status through a Scheme-readable manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib comparator)))
            (scheme-alias (stdlib-manifest-ref '(scheme comparator)))
            (alias (stdlib-manifest-ref '(srfi 128)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-128))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib comparator))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (equal? (manifest-field entry 'aliases)
                     '((scheme comparator) (srfi 128) (srfi srfi-128)))
             (equal?
              (manifest-field entry 'dependencies)
              '((library (scheme base))
                (library (scheme case-lambda))
                (library (scheme char))
                (library (scheme inexact))
                (library (scheme complex))))
             (equal? (manifest-field scheme-alias 'target)
                     '(stdlib comparator))
             (equal? (manifest-field alias 'target) '(stdlib comparator))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib comparator))))")
    "#t")))

(ert-deftest consent-library-test-stdlib-rbtree-import ()
  "Import internal `(stdlib rbtree)' and exercise representative tree behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (stdlib comparator)
              (stdlib rbtree))
      (define integer-comparator
        (make-comparator integer? = < number-hash))
      (define (tree-insert tree key value)
        (call-with-values
         (lambda ()
           (tree-search integer-comparator
                        tree
                        key
                        (lambda (insert ignore)
                          (insert key value 'inserted))
                        (lambda (old-key old-value update remove)
                          (update old-key value 'updated))))
         (lambda (next status) next)))
      (define tree
        (tree-insert
         (tree-insert
          (tree-insert (make-tree) 2 'two)
          1
          'one)
         3
         'three))
      (list
       (tree-fold/reverse
        (lambda (key value acc)
          (cons (cons key value) acc))
        '()
        tree)
       (tree-key-successor integer-comparator tree 1 (lambda () 'none))
       (tree-key-predecessor integer-comparator tree 3 (lambda () 'none)))")
    "(((1 . one) (2 . two) (3 . three)) 2 2)")))

(ert-deftest consent-library-test-stdlib-rbtree-missing-export-diagnostic ()
  "Report missing rbtree imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (stdlib rbtree) missing-rbtree))
            missing-rbtree")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-rbtree")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-rbtree ()
  "Expose rbtree helper support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib rbtree))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib rbtree))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (not (manifest-field entry 'aliases))
             (equal?
              (manifest-field entry 'dependencies)
              '((library (scheme base))
                (library (scheme case-lambda))
                (library (stdlib and-let-star))
                (library (stdlib receive))
                (library (stdlib generator))
                (library (stdlib comparator))))))")
    "#t")))

(ert-deftest consent-library-test-srfi-146-mapping-behavior ()
  "Import primary `(scheme mapping)' and exercise ordered SRFI 146 behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (scheme comparator)
              (scheme mapping))
      (define integer-comparator
        (make-comparator integer? = < number-hash))
      (define base
        (mapping integer-comparator 3 'three 1 'one 2 'two 2 'TWO))
      (define updated
        (mapping-set base 4 'four 2 'TWO))
      (define without-one
        (mapping-delete updated 1))
      (list (mapping? base)
            (mapping-size base)
            (mapping-ref base 2)
            (mapping->alist updated)
            (mapping-keys updated)
            (mapping-values updated)
            (mapping-min-key updated)
            (mapping-max-key updated)
            (mapping-key-predecessor updated 3 (lambda () 'none))
            (mapping-key-successor updated 3 (lambda () 'none))
            (mapping->alist (mapping-range>= updated 3))
            (mapping-ref/default without-one 1 'missing)
            (mapping-size
             (mapping-intersection
              updated
              (mapping integer-comparator 2 'TWO 4 'four 9 'nine))))")
    "(#t 3 two ((1 . one) (2 . TWO) (3 . three) (4 . four)) (1 2 3 4) (one TWO three four) 1 4 2 4 ((3 . three) (4 . four)) missing 2)")))

(ert-deftest consent-library-test-srfi-146-alias-import ()
  "Import SRFI 146 through its secondary `(srfi 146)' alias."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (scheme comparator)
              (srfi 146))
      (let* ((comparator (make-comparator integer? = < number-hash))
             (mapping (mapping comparator 10 'ten 20 'twenty)))
        (list (mapping-ref/default mapping 20 'missing)
              (mapping-ref/default mapping 30 'missing)))")
    "(twenty missing)")))

(ert-deftest consent-library-test-srfi-146-portable-alias-import ()
  "Import SRFI 146 through its portable `(srfi srfi-146)' alias."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (scheme comparator)
              (srfi srfi-146))
      (let* ((comparator (make-comparator integer? = < number-hash))
             (mapping (alist->mapping comparator '((2 . two) (1 . one)))))
        (mapping->alist mapping))")
    "((1 . one) (2 . two))")))

(ert-deftest consent-library-test-srfi-146-aliases-export-same-core-surface ()
  "Keep `(scheme mapping)' and SRFI 146 aliases on the same ordered-map surface."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (scheme comparator)
              (rename (scheme mapping)
                      (mapping scheme-mapping)
                      (mapping->alist scheme-mapping->alist))
              (rename (srfi 146)
                      (mapping srfi-mapping)
                      (mapping->alist srfi-mapping->alist))
              (rename (srfi srfi-146)
                      (mapping portable-mapping)
                      (mapping->alist portable-mapping->alist)))
      (define comparator
        (make-comparator integer? = < number-hash))
      (list (scheme-mapping->alist (scheme-mapping comparator 2 'two 1 'one))
            (srfi-mapping->alist (srfi-mapping comparator 2 'two 1 'one))
            (portable-mapping->alist
             (portable-mapping comparator 2 'two 1 'one)))")
    "(((1 . one) (2 . two)) ((1 . one) (2 . two)) ((1 . one) (2 . two)))")))

(ert-deftest consent-library-test-srfi-146-missing-export-diagnostic ()
  "Report missing SRFI 146 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (scheme mapping) missing-mapping))
            missing-mapping")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-mapping")
      (error-message-string error)))))

(ert-deftest consent-library-test-srfi-146-hash-alias-remains-unsupported ()
  "Report the out-of-scope SRFI 146 hash alias as an unknown library."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (srfi 146 hash))
            'unreachable")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "unknown library")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "(srfi 146 hash)")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-146 ()
  "Expose ordered SRFI 146 mapping status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib mapping)))
            (scheme-alias (stdlib-manifest-ref '(scheme mapping)))
            (alias (stdlib-manifest-ref '(srfi 146)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-146)))
            (hash-alias (stdlib-manifest-ref '(srfi 146 hash))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib mapping))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (equal? (manifest-field entry 'aliases)
                     '((scheme mapping) (srfi 146) (srfi srfi-146)))
             (equal?
              (manifest-field entry 'dependencies)
              '((library (scheme base))
                (library (scheme case-lambda))
                (library (stdlib list))
                (library (stdlib receive))
                (library (stdlib comparator))
                (library (stdlib assume))
                (library (stdlib rbtree))))
             (equal? (manifest-field scheme-alias 'target)
                     '(stdlib mapping))
             (equal? (manifest-field alias 'target) '(stdlib mapping))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib mapping))
             (not hash-alias)))")
    "#t")))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-16-shim ()
  "Expose SRFI 16 shim status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(srfi 16)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-16))))
        (and (eq? (car entry) 'manifest-index-entry)
             (equal? (manifest-field entry 'status) 'built-in-shim)
             (equal? (manifest-field entry 'source) 'built-in-shim)
             (equal? (manifest-field entry 'target) '(scheme case-lambda))
             (equal? (manifest-field entry 'aliases) '((srfi srfi-16)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme case-lambda))))
             (equal? (manifest-field portable-alias 'target)
                     '(scheme case-lambda))))")
    "#t")))

(ert-deftest consent-library-test-standard-char-and-cxr-imports ()
  "Import `(scheme char)' and `(scheme cxr)' bindings."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme char) (scheme cxr))
      (list (char-upcase #\\a)
            (char-downcase #\\Z)
            (char-foldcase #\\A)
            (char-alphabetic? #\\A)
            (char-numeric? #\\9)
            (char-whitespace? #\\space)
            (digit-value #\\9)
            (char-ci=? #\\A #\\a)
            (string-upcase \"Az\")
            (string-ci<? \"abc\" \"BCD\")
            (cadddr '(a b c d e)))")
    "(#\\A #\\z #\\a #t #t #t 9 #t \"AZ\" #t d)")))

(ert-deftest consent-library-test-standard-lazy-import-memoizes ()
  "Import `(scheme lazy)' promises with memoizing force."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme lazy))
      (let ((count 0))
        (let ((promise
               (delay
                 (begin
                   (set! count (+ count 1))
                   count))))
          (list (force promise)
                (force promise)
                count)))")
    "(1 1 1)")))

(ert-deftest consent-library-test-standard-write-import-string-output ()
  "Import `(scheme write)' in-memory string output procedures."
  (should
   (equal
   (consent-library-test--external
     "(import (scheme base) (scheme write))
      (let ((out (open-output-string)))
        (display \"ok\" out)
        (get-output-string out))")
    "\"ok\"")))

(ert-deftest consent-library-test-standard-write-shared-and-record-output ()
  "Import `(scheme write)' shared, simple, and record writer procedures."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme write))
      (let ((x (list 'a)))
        (let ((out (open-output-string)))
          (write-shared (list x x) out)
          (get-output-string out)))")
    "\"(#0=(a) #0#)\""))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme write))
      (let ((x (list 'a)))
        (let ((out (open-output-string)))
          (write (list x x) out)
          (get-output-string out)))")
    "\"((a) (a))\""))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme write))
      (let ((out (open-output-string)))
        (write '#1=(a . #1#) out)
        (get-output-string out))")
    "\"#0=(a . #0#)\""))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme write))
      (let ((out (open-output-string)))
        (write-simple '#(1 \"x\") out)
        (get-output-string out))")
    "\"#(1 \\\"x\\\")\""))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme write))
      (define-record-type <pare>
        (kons x y)
        pare?
        (x kar)
        (y kdr))
      (let ((out (open-output-string)))
        (write (kons 1 2) out)
        (get-output-string out))")
    "\"#<record <pare>>\"")))

(ert-deftest consent-library-test-string-ports-read-and-write-round-trip ()
  "Use pure textual string ports with the Consent Scheme reader and writer."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme read) (scheme write))
      (let ((in (open-input-string \"(alpha 1) \"))
            (out (open-output-string)))
        (write (read in) out)
        (write-char (read-char in) out)
        (list (get-output-string out)
              (eof-object? (read in))))")
    "(\"(alpha 1) \" #t)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme read) (scheme write))
      (let ((out (open-output-string)))
        (write '(a \"b\" #u8(1 2)) out)
        (read (open-input-string (get-output-string out))))")
    "(a \"b\" #u8(1 2))")))

(ert-deftest consent-library-test-bytevector-ports-read-and-write ()
  "Use pure binary bytevector ports without host file access."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base))
      (let ((in (open-input-bytevector #u8(1 2 3)))
            (out (open-output-bytevector)))
        (write-u8 (read-u8 in) out)
        (write-bytevector (read-bytevector 4 in) out)
        (list (eof-object? (read-u8 in))
              (get-output-bytevector out)))")
    "(#t #u8(1 2 3))")))

(ert-deftest consent-library-test-standard-eval-import-evaluates-scheme ()
  "Evaluate Scheme datums in explicit immutable Scheme environments."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme eval))
      (eval '(* 7 3) (environment '(scheme base)))")
    "21"))
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme eval))
     (eval '(define foo 32) (environment '(scheme base)))")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-standard-load-is-policy-gated ()
  "Load Scheme source only when host file policy allows the path."
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme load))
     (load \"fixtures/r7rs/include-body.scm\")")
   :type 'consent-eval-error)
  (should
   (equal
    (consent-library-test--external/options
     "(import (scheme base) (scheme load))
      (load \"fixtures/r7rs/include-body.scm\")
      answer"
     consent-library-test--include-options)
    "42")))

(ert-deftest consent-library-test-standard-file-import-is-policy-gated ()
  "Keep `(scheme file)' host file effects behind explicit path policy."
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme file))
     (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")
   :type 'consent-eval-error)
  (should
   (equal
    (consent-library-test--external/options
     "(import (scheme base) (scheme file))
      (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
     consent-library-test--include-options)
    "#t")))

(ert-deftest consent-library-test-file-grant-authorizes-metadata-and-audits ()
  "Authorize `(scheme file)' metadata through a file capability grant."
  (consent-audit-clear)
  (should
   (equal
    (consent-library-test--external/options
     "(import (scheme base) (scheme file))
      (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
     (consent-library-test--file-grant-options))
    "#t"))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-request)"
    "(domain file)"
    "(operation metadata)"
    "(path \"fixtures/r7rs/conformance-cases.scm\")"))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-decision)"
    "(status approved)"
    "(grant fixture-file-grant)"))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-handle)"
    "(domain file)"
    "(kind file)"
    "(grant fixture-file-grant)"
    "(status live)"))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-audit)"
    "(result (ok #t))")))

(ert-deftest consent-library-test-file-grant-authorizes-include-and-load ()
  "Authorize include and load reads through the same file grant vocabulary."
  (consent-audit-clear)
  (let ((options (consent-library-test--file-grant-options)))
    (should
     (equal
      (consent-library-test--external/options
       "(define-library (consent fixture include-body)
          (export answer)
          (import (scheme base))
          (include \"fixtures/r7rs/include-body.scm\"))
        (import (consent fixture include-body))
        answer"
       options)
      "42"))
    (should
     (equal
      (consent-library-test--external/options
       "(define-library (consent fixture include-ci-body)
          (export mixedanswer)
          (import (scheme base))
          (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
        (import (consent fixture include-ci-body))
        mixedanswer"
       options)
      "42"))
    (should
     (equal
      (consent-library-test--external/options
       "(import (scheme base) (scheme load))
        (load \"fixtures/r7rs/include-body.scm\")
        answer"
       options)
      "42"))
    (should
     (consent-library-test--audit-entry-matching
      "(event capability-request)"
      "(domain code-loading)"
      "(operation load)"
      "(binding \"load\")"))
    (should
     (consent-library-test--audit-entry-matching
      "(event capability-decision)"
      "(domain code-loading)"
      "(status approved)"))
    (should
     (consent-library-test--audit-entry-matching
      "(event capability-audit)"
      "(domain code-loading)"
      "(result (ok evaluated))"))))

(ert-deftest consent-library-test-file-grant-denies-path-traversal ()
  "Deny normalized paths that escape the approved file grant path."
  (let ((condition
         (should-error
          (consent-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"fixtures/r7rs/../../AGENTS.md\")"
           nil
           (consent-library-test--file-grant-options))
          :type 'consent-eval-error)))
    (should
     (string-match-p "file capability denied" (cadr condition)))))

(ert-deftest consent-library-test-file-grant-denies-symlink-escape ()
  "Resolve symlinks and deny targets outside the approved file grant path."
  (let* ((root (make-temp-file "consent-file-capability-" t))
         (allowed (expand-file-name "allowed" root))
         (outside (expand-file-name "outside.scm" root))
         (link (expand-file-name "escape.scm" allowed)))
    (unwind-protect
        (progn
          (consent-library-test--write-file outside "(define escaped 1)")
          (make-directory allowed t)
          (condition-case nil
              (make-symbolic-link outside link)
            (file-error
             (ert-skip "symlink creation is unavailable on this host")))
          (consent-audit-clear)
          (let ((condition
                 (should-error
                  (consent-eval-source
                   "(import (scheme base) (scheme file))
                    (file-exists? \"allowed/escape.scm\")"
                   nil
                   (consent-library-test--file-grant-options
                    root '("allowed") '(metadata)))
                  :type 'consent-eval-error)))
            (should
             (string-match-p "file capability denied" (cadr condition))))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-decision)"
            "(status denied)"
            "symlink")))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-grant-denies-url-paths ()
  "Keep URLs outside ordinary file-domain grants."
  (consent-audit-clear)
  (let ((condition
         (should-error
          (consent-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"https://example.invalid/source.scm\")"
           nil
           (consent-library-test--file-grant-options
            "/" '("/") '(metadata)))
          :type 'consent-eval-error)))
    (should
     (string-match-p "file capability denied" (cadr condition))))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-decision)"
    "(status denied)"
    "remote file paths")))

(ert-deftest consent-library-test-file-grant-authorizes-delete-file ()
  "Authorize `(scheme file)' deletion through a file capability grant."
  (let* ((root (make-temp-file "consent-file-delete-" t))
         (allowed (expand-file-name "allowed" root))
         (target (expand-file-name "remove.scm" allowed))
         (options
          (consent-library-test--file-grant-options
           root
           '("allowed")
           '(metadata delete))))
    (unwind-protect
        (progn
          (consent-library-test--write-file target "(define old 1)")
          (consent-audit-clear)
          (should
           (equal
            (consent-library-test--external/options
             "(import (scheme base) (scheme file))
              (delete-file \"allowed/remove.scm\")
              (file-exists? \"allowed/remove.scm\")"
             options)
            "#f"))
          (should-not (file-exists-p target))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-request)"
            "(domain file)"
            "(operation delete)"
            "(path \"allowed/remove.scm\")"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-decision)"
            "(status approved)"
            "(grant fixture-file-grant)"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-audit)"
            "(operation delete)"
            "(result (ok deleted))")))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-grant-authorizes-input-file-port ()
  "Authorize host-backed input file ports through file and port capabilities."
  (let* ((root (make-temp-file "consent-file-port-input-" t))
         (target (expand-file-name "allowed/input.scm" root))
         (options
          (consent-library-test--file-grant-options
           root
           '("allowed")
           '(read))))
    (unwind-protect
        (progn
          (consent-library-test--write-file target "abc")
          (consent-audit-clear)
          (should
           (equal
            (consent-library-test--external/options
             "(import (scheme base) (scheme file))
              (let ((port (open-input-file \"allowed/input.scm\")))
                (list (input-port? port)
                      (textual-port? port)
                      (read-string 2 port)
                      (read-string 2 port)
                      (eof-object? (read-char port))))"
             options)
            "(#t #t \"ab\" \"c\" #t)"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-handle)"
            "(domain port)"
            "(backing file)"
            "(operations (read close))"
            "(grant fixture-file-grant)"
            "(status open)"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-audit)"
            "(domain port)"
            "(operation read)"
            "(result (ok 2))")))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-grant-authorizes-output-file-port ()
  "Authorize host-backed output file ports before creating host files."
  (let* ((root (make-temp-file "consent-file-port-output-" t))
         (target (expand-file-name "allowed/output.scm" root))
         (options
          (consent-library-test--file-grant-options
           root
           '("allowed")
           '(create))))
    (unwind-protect
        (progn
          (make-directory (file-name-directory target) t)
          (consent-audit-clear)
          (should
           (equal
            (consent-library-test--external/options
             "(import (scheme base) (scheme file))
              (let ((port (open-output-file \"allowed/output.scm\")))
                (write-string \"created\" port)
                (close-port port)
                (output-port-open? port))"
             options)
            "#f"))
          (with-temp-buffer
            (insert-file-contents target)
            (should (equal (buffer-string) "created")))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-request)"
            "(domain file)"
            "(operation create)"
            "(path \"allowed/output.scm\")"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-handle)"
            "(domain port)"
            "(backing file)"
            "(operations (write flush close))"
            "(grant fixture-file-grant)"
            "(status open)"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-audit)"
            "(domain port)"
            "(operation write)"
            "(result (ok 7))"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-audit)"
            "(domain port)"
            "(operation close)"
            "(result (ok closed))")))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-grant-authorizes-binary-file-ports ()
  "Authorize host-backed binary file ports through file and port capabilities."
  (let* ((root (make-temp-file "consent-binary-file-port-" t))
         (input (expand-file-name "allowed/input.bin" root))
         (output (expand-file-name "allowed/output.bin" root))
         (options
          (consent-library-test--file-grant-options
           root
           '("allowed")
           '(read create))))
    (unwind-protect
        (progn
          (consent-library-test--write-binary-file
           input
           '(1 2 3 4 255))
          (consent-audit-clear)
          (should
           (equal
            (consent-library-test--external/options
             "(import (scheme base) (scheme file))
              (let ((in (open-binary-input-file \"allowed/input.bin\"))
                    (out (open-binary-output-file \"allowed/output.bin\")))
                (write-u8 (read-u8 in) out)
                (write-bytevector (read-bytevector 4 in) out)
                (close-port out)
                (list (binary-port? in)
                      (eof-object? (read-u8 in))
                      (output-port-open? out)))"
             options)
            "(#t #t #f)"))
          (should
           (equal
            (consent-library-test--read-binary-file output)
            '(1 2 3 4 255)))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-handle)"
            "(domain port)"
            "(kind binary-input)"
            "(backing file)"
            "(operations (read close))"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-handle)"
            "(domain port)"
            "(kind binary-output)"
            "(backing file)"
            "(operations (write flush close))")))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-port-wrappers-use-capabilities ()
  "Authorize file port wrapper procedures before host port creation."
  (let* ((root (make-temp-file "consent-file-port-wrappers-" t))
         (input (expand-file-name "allowed/input.scm" root))
         (call-output (expand-file-name "allowed/call-output.scm" root))
         (with-output (expand-file-name "allowed/with-output.scm" root))
         (options
          (consent-library-test--file-grant-options
           root
           '("allowed")
           '(read create))))
    (unwind-protect
        (progn
          (consent-library-test--write-file input "input")
          (consent-audit-clear)
          (should
           (equal
            (consent-library-test--external/options
             "(import (scheme base) (scheme file))
              (list
               (call-with-input-file
                \"allowed/input.scm\"
                (lambda (port) (read-string 5 port)))
               (with-input-from-file
                \"allowed/input.scm\"
                (lambda () (read-string 5)))
               (begin
                 (call-with-output-file
                  \"allowed/call-output.scm\"
                  (lambda (port) (write-string \"call\" port)))
                 'call-done)
               (begin
                 (with-output-to-file
                  \"allowed/with-output.scm\"
                  (lambda () (write-string \"with\")))
                 'with-done))"
             options)
            "(\"input\" \"input\" call-done with-done)"))
          (with-temp-buffer
            (insert-file-contents call-output)
            (should (equal (buffer-string) "call")))
          (with-temp-buffer
            (insert-file-contents with-output)
            (should (equal (buffer-string) "with")))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-request)"
            "(domain file)"
            "(operation create)"
            "(path \"allowed/call-output.scm\")"))
          (should
           (consent-library-test--audit-entry-matching
            "(event capability-request)"
            "(domain file)"
            "(operation create)"
            "(path \"allowed/with-output.scm\")")))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-default-current-ports-are-policy-gated ()
  "Deny default current ports unless a dynamic file wrapper binds them."
  (consent-audit-clear)
  (let ((input-condition
         (should-error
          (consent-eval-source
           "(import (scheme base))
            (current-input-port)")
          :type 'consent-policy-error))
        (output-condition
         (should-error
          (consent-eval-source
           "(import (scheme base))
            (current-output-port)")
          :type 'consent-policy-error)))
    (should
     (string-match-p "current-input-port requires policy-gated host access"
                     (cadr input-condition)))
    (should
     (string-match-p "current-output-port requires policy-gated host access"
                     (cadr output-condition))))
  (should
   (consent-library-test--audit-entry-matching
    "(event policy-decision)"
    "(operation \"current-input-port\")"
    "(decision denied)"))
  (should
   (consent-library-test--audit-entry-matching
    "(event policy-decision)"
    "(operation \"current-output-port\")"
    "(decision denied)")))

(ert-deftest consent-library-test-file-port-close-invalidates-handle ()
  "Reject reads through a closed host-backed file port as stale handles."
  (let* ((root (make-temp-file "consent-file-port-close-" t))
         (target (expand-file-name "allowed/input.scm" root))
         (options
          (consent-library-test--file-grant-options
           root
           '("allowed")
           '(read))))
    (unwind-protect
        (progn
          (consent-library-test--write-file target "abc")
          (consent-audit-clear)
          (let ((condition
                 (should-error
                  (consent-eval-source
                   "(import (scheme base) (scheme file))
                    (let ((port (open-input-file \"allowed/input.scm\")))
                      (close-port port)
                      (read-char port))"
                   nil
                   options)
                  :type 'consent-capability-grant-error)))
            (should
             (string-match-p "stale port capability handle"
                             (cadr condition)))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-port-revoked-grant-is-stale ()
  "Reject host-backed file ports after their backing file grant is revoked."
  (let* ((root (make-temp-file "consent-file-port-revoked-" t))
         (target (expand-file-name "allowed/input.scm" root)))
    (unwind-protect
        (progn
          (consent-library-test--write-file target "abc")
          (consent-audit-clear)
          (let ((condition
                 (should-error
                  (consent-eval-source
                   (format
                    "(import (scheme base) (scheme file) (consent capability))
                     (grant-capability!
                      '(capability-grant
                        (id revoked-port-grant)
                        (domain file)
                        (operations read)
                        (scope (project-root %S)
                               (paths (\"allowed\"))
                               (remote denied)
                               (symlinks resolve-within-root))
                        (expires never)))
                     (let ((port (open-input-file \"allowed/input.scm\")))
                       (grant-revoke! 'revoked-port-grant)
                       (read-char port))"
                    (file-name-as-directory (expand-file-name root)))
                   nil
                   (list :include-directory root))
                  :type 'consent-capability-grant-error)))
            (should
             (string-match-p "stale port capability handle"
                             (cadr condition)))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-port-read-limit-is-enforced ()
  "Deny host-backed file port reads after the declared port limit is spent."
  (let* ((root (make-temp-file "consent-file-port-limit-" t))
         (target (expand-file-name "allowed/input.scm" root)))
    (unwind-protect
        (progn
          (consent-library-test--write-file target "abc")
          (consent-audit-clear)
          (let ((condition
                 (should-error
                  (consent-eval-source
                   (format
                    "(import (scheme base) (scheme file) (consent capability))
                     (grant-capability!
                      '(capability-grant
                        (id limited-port-grant)
                        (domain file)
                        (operations read)
                        (scope (project-root %S)
                               (paths (\"allowed\"))
                               (remote denied)
                               (symlinks resolve-within-root))
                        (limits (reads 1))
                        (expires never)))
                     (let ((port (open-input-file \"allowed/input.scm\")))
                       (read-char port)
                       (read-char port))"
                    (file-name-as-directory (expand-file-name root)))
                   nil
                   (list :include-directory root))
                  :type 'consent-capability-grant-error)))
            (should
             (string-match-p "port capability limit exceeded: reads"
                             (cadr condition)))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-port-close-limit-allows-close ()
  "Spend one close limit unit for one host-backed output port close."
  (let* ((root (make-temp-file "consent-file-port-close-limit-" t))
         (target (expand-file-name "allowed/output.scm" root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory target) t)
          (should
           (equal
            (consent-value->external
             (consent-eval-source
              (format
               "(import (scheme base) (scheme file) (consent capability))
                (grant-capability!
                 '(capability-grant
                   (id close-limited-port-grant)
                   (domain file)
                   (operations create)
                   (scope (project-root %S)
                          (paths (\"allowed\"))
                          (remote denied)
                          (symlinks resolve-within-root))
                   (limits (closes 1))
                   (expires never)))
                (let ((port (open-output-file \"allowed/output.scm\")))
                  (write-string \"x\" port)
                  (close-port port)
                  (output-port-open? port))"
               (file-name-as-directory (expand-file-name root)))
              nil
              (list :include-directory root)))
            "#f"))
          (with-temp-buffer
            (insert-file-contents target)
            (should (equal (buffer-string) "x"))))
      (when (file-exists-p root)
        (delete-directory root t)))))

(ert-deftest consent-library-test-file-grant-revocation-denies-and-audits ()
  "Represent file grant revocation and deny later file access."
  (consent-audit-clear)
  (let* ((root (file-name-as-directory consent-library-test--root))
         (condition
          (should-error
           (consent-eval-source
            (format
             "(import (scheme base) (scheme file) (consent capability))
              (grant-capability!
               '(capability-grant
                 (id revoked-file-grant)
                 (domain file)
                 (operations metadata)
                 (scope (project-root %S)
                        (paths (\"fixtures/r7rs\"))
                        (remote denied)
                        (symlinks resolve-within-root))
                 (expires never)))
              (grant-revoke! 'revoked-file-grant)
              (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
             root)
            nil
            (list :include-directory root))
           :type 'consent-capability-grant-error)))
    (should
     (string-match-p "revoked file capability grant" (cadr condition))))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-revocation)"
    "(target (grant revoked-file-grant))"
    "(status revoked)"))
  (should
   (consent-library-test--audit-entry-matching
    "(event capability-decision)"
    "(status denied)"
    "(grant revoked-file-grant)"
    "revoked file capability grant")))

(ert-deftest consent-library-test-standard-host-libraries-are-policy-gated ()
  "Import host-effecting standard libraries while denying effects by default."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme process-context) (scheme time) (scheme repl))
      'ok")
    "ok"))
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme process-context))
     (command-line)")
   :type 'consent-eval-error)
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme time))
     (current-second)")
   :type 'consent-eval-error)
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme repl))
     (interaction-environment)")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-standard-r5rs-import ()
  "Import the practical R5RS compatibility layer."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme r5rs))
      (list (+ 1 2)
            (exact->inexact 3)
            (inexact->exact 3.0))")
    "(3 3.0 3)")))

(ert-deftest consent-library-test-imported-values-are-immutable ()
  "Reject definitions and assignments that target imported values."
  (should-error
   (consent-eval-source
    "(import (scheme base))
     (set! + 1)"
    (consent-make-empty-environment))
   :type 'consent-eval-error)
  (should-error
   (consent-eval-source
    "(import (scheme base))
     (define + 1)"
    (consent-make-empty-environment))
   :type 'consent-eval-error))

(ert-deftest consent-library-test-imported-syntax-is-immutable ()
  "Reject syntax definitions that target imported keywords."
  (should-error
   (consent-eval-source
    "(import (scheme base))
     (define-syntax and
       (syntax-rules ()
         ((and) #t)))"
    (consent-make-empty-environment))
   :type 'consent-eval-error))

(ert-deftest consent-library-test-duplicate-export-names-signal-error ()
  "Reject duplicate external names in a library export set."
  (should-error
   (consent-eval-source
    "(define-library (consent fixture duplicate-export)
       (export value value)
       (import (scheme base))
       (begin (define value 1)))")
   :type 'consent-eval-error))

(ert-deftest consent-library-test-program-imports-precede-body ()
  "Reject program imports after definitions or expressions begin."
  (should-error
   (consent-eval-source
    "(import (scheme base))
     1
     (import (scheme cxr))
     'ok"
    (consent-make-empty-environment))
   :type 'consent-eval-error))

;;; consent-library-test.el ends here
