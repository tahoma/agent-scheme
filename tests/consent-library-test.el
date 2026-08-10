;;; consent-library-test.el -*- lexical-binding: t; -*-
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

(defconst consent-library-test--srfi-97-library-references
  '((1 "(srfi :1)" "(srfi :1 lists)")
    (2 "(srfi :2)" "(srfi :2 and-let*)")
    (5 "(srfi :5)" "(srfi :5 let)")
    (6 "(srfi :6)" "(srfi :6 basic-string-ports)")
    (8 "(srfi :8)" "(srfi :8 receive)")
    (9 "(srfi :9)" "(srfi :9 records)")
    (11 "(srfi :11)" "(srfi :11 let-values)")
    (13 "(srfi :13)" "(srfi :13 strings)")
    (14 "(srfi :14)" "(srfi :14 char-sets)")
    (16 "(srfi :16)" "(srfi :16 case-lambda)")
    (17 "(srfi :17)" "(srfi :17 generalized-set!)")
    (18 "(srfi :18)" "(srfi :18 multithreading)")
    (19 "(srfi :19)" "(srfi :19 time)")
    (21 "(srfi :21)" "(srfi :21 real-time-multithreading)")
    (23 "(srfi :23)" "(srfi :23 error)")
    (25 "(srfi :25)" "(srfi :25 multi-dimensional-arrays)")
    (26 "(srfi :26)" "(srfi :26 cut)")
    (27 "(srfi :27)" "(srfi :27 random-bits)")
    (28 "(srfi :28)" "(srfi :28 basic-format-strings)")
    (29 "(srfi :29)" "(srfi :29 localization)")
    (31 "(srfi :31)" "(srfi :31 rec)")
    (38 "(srfi :38)" "(srfi :38 with-shared-structure)")
    (39 "(srfi :39)" "(srfi :39 parameters)")
    (41 "(srfi :41)" "(srfi :41 streams)"
        "(srfi :41 streams primitive)" "(srfi :41 streams derived)")
    (42 "(srfi :42)" "(srfi :42 eager-comprehensions)")
    (43 "(srfi :43)" "(srfi :43 vectors)")
    (44 "(srfi :44)" "(srfi :44 collections)")
    (45 "(srfi :45)" "(srfi :45 lazy)")
    (46 "(srfi :46)" "(srfi :46 syntax-rules)")
    (47 "(srfi :47)" "(srfi :47 arrays)")
    (48 "(srfi :48)" "(srfi :48 intermediate-format-strings)")
    (51 "(srfi :51)" "(srfi :51 rest-values)")
    (54 "(srfi :54)" "(srfi :54 cat)")
    (57 "(srfi :57)" "(srfi :57 records)")
    (59 "(srfi :59)" "(srfi :59 vicinities)")
    (60 "(srfi :60)" "(srfi :60 integer-bits)")
    (61 "(srfi :61)" "(srfi :61 cond)")
    (63 "(srfi :63)" "(srfi :63 arrays)")
    (64 "(srfi :64)" "(srfi :64 testing)")
    (66 "(srfi :66)" "(srfi :66 octet-vectors)")
    (67 "(srfi :67)" "(srfi :67 compare-procedures)")
    (69 "(srfi :69)" "(srfi :69 basic-hash-tables)")
    (71 "(srfi :71)" "(srfi :71 let)")
    (74 "(srfi :74)" "(srfi :74 blobs)")
    (78 "(srfi :78)" "(srfi :78 lightweight-testing)")
    (86 "(srfi :86)" "(srfi :86 mu-and-nu)")
    (87 "(srfi :87)" "(srfi :87 case=>)")
    (95 "(srfi :95)" "(srfi :95 sorting-and-merging)"))
  "SRFI 97 library references keyed by SRFI number.")

(defconst consent-library-test--srfi-261-omitted-srfis
  '(0 4 7 10 30 34 35 36 49 55 58 62 70 72 88 89 90 94 96 97
      105 106 107 108 109 110 118 119 120 123 124 135 144 147
      148 149 150 160 161 164 169 185 188 207)
  "SRFI 261 omitted SRFIs that cannot be plain SRFI libraries.")

(defconst consent-library-test--root
  (expand-file-name
   ".."
   (file-name-directory (or load-file-name buffer-file-name
     default-directory)))
  "Repository root for library fixture tests.")

(defconst consent-library-test--stdlib-manifest-directory
  (expand-file-name "scheme/stdlib/" consent-library-test--root)
  "Directory containing the stdlib collection manifest.")

(defconst consent-library-test--data-manifest-directory
  (expand-file-name "scheme/data/" consent-library-test--root)
  "Directory containing the data collection manifest.")

(defun consent-library-test--manifest-source-file (key)
  "Return the absolute manifest-declared source file for library KEY."
  (let ((entry (consent--library-collection-manifest-entry key)))
    (and entry
         (plist-get entry :source-file)
         (consent--manifest-source-library-file
          (plist-get entry :source-file)
          (plist-get entry :root)))))

(defun consent-library-test--cached-source-entry
    (root &optional realization visibility)
  "Return a test source-library entry rooted at ROOT."
  (list :name "(test cached-source)"
        :source-kind 'portable-source
        :source-file "cached-source.sld"
        :root root
        :exports-declared t
        :exports '("value" "text" "items" "bytes")
        :visibility (or visibility 'public)
        :realization (or realization 'portable-source)))

(defun consent-library-test--write-cached-source (root value)
  "Write the cached source-library fixture under ROOT with VALUE."
  (write-region
   (format
    "(define-library (test cached-source)
  (export value text items bytes)
  (import (scheme base))
  (begin
    (define value %s)
    (define text \"fresh\")
    (define items #(1 2))
    (define bytes #u8(3 4))))
"
    value)
   nil
   (expand-file-name "cached-source.sld" root)))

(defun consent-library-test--register-cached-source (entry &optional options)
  "Register test source-library ENTRY in a fresh context using OPTIONS."
  (let ((context (consent--new-eval-context options))
        (environment (consent-make-base-environment)))
    (consent--register-scheme-base-library context environment)
    (consent--register-manifest-source-library entry context environment)
    (cons context
          (gethash (plist-get entry :name)
                   (consent--eval-context-libraries context)))))

(defun consent-library-test--cached-source-value (library name)
  "Return exported NAME's value from cached source LIBRARY."
  (consent--environment-ref
   (consent--library-value-environment library)
   name))

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
      collection collection collection collection collection collection
        source-root)
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

(defun consent-library-test--record-field (record field)
  "Return FIELD from Scheme-readable RECORD."
  (cadr (assoc (consent--syntax-symbol (symbol-name field)) (cdr record))))

(defun consent-library-test--record-field-external (record field)
  "Return FIELD from Scheme-readable RECORD rendered as external Scheme."
  (consent-datum->external
   (consent-library-test--record-field record field)))

(defun consent-library-test--vendored-srfi-record (number)
  "Return vendored SRFI NUMBER's source-backed intake record."
  (require 'consent-reflect)
  (consent-reflect-vendored-srfi-manifest
   (consent--make-canonical-integer number)))

(defun consent-library-test--srfi-261-pure-library-entry-p (entry)
  "Return non-nil when ENTRY resolves to a source-backed SRFI library."
  (let* ((resolved-key (consent--library-entry-resolved-name entry))
         (resolved-entry
          (and resolved-key (consent--library-catalog-lookup resolved-key))))
    (and resolved-entry
         (eq (plist-get resolved-entry :category) 'stdlib)
         (eq (plist-get resolved-entry :kind) 'library)
         (eq (plist-get resolved-entry :source-kind) 'portable-source)
         (eq (plist-get resolved-entry :realization) 'portable-source)
         (plist-get resolved-entry :source-file)
         (not (plist-get resolved-entry :target))
         (not (plist-get resolved-entry :implementation-resolver))
         (not (plist-get resolved-entry :primitive-overlay-library))
         (not (plist-get resolved-entry :primitive-exports))
         (not (plist-get resolved-entry :effects))
         (not (plist-get resolved-entry :capabilities)))))

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
                   ("(scheme cxr)"
                    ("caaar" "caadr" "cadar" "caddr"
                     "cdaar" "cdadr" "cddar" "cdddr"
                     "caaaar" "caaadr" "caadar" "caaddr"
                     "cadaar" "cadadr" "caddar" "cadddr"
                     "cdaaar" "cdaadr" "cdadar" "cdaddr"
                     "cddaar" "cddadr" "cdddar" "cddddr")
                    "scheme/consent/cxr.sld")
                   ("(scheme char)"
                    ("char-alphabetic?"
                     "char-ci<=?" "char-ci<?" "char-ci=?"
                     "char-ci>=?" "char-ci>?"
                     "char-downcase" "char-foldcase" "char-lower-case?"
                     "char-numeric?" "char-upcase" "char-upper-case?"
                     "char-whitespace?" "digit-value"
                     "string-ci<=?" "string-ci<?" "string-ci=?"
                     "string-ci>=?" "string-ci>?"
                     "string-downcase" "string-foldcase" "string-upcase")
                    "scheme/consent/char.sld")
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
       (cadr (assq 'status (cdr (session-store-retire! store\
 'source-alpha)))))")
    "(source-alpha source-alpha (source-alpha source-beta) suspended active\
 source-snap source-beta retired)")))

(ert-deftest consent-library-test-testing-harness-is-source-backed ()
  "Expose the reusable portable test harness through the runtime catalog."
  (let* ((entry
          (consent--library-collection-manifest-entry
           "(testing harness)"))
         (source-file
          (consent-library-test--manifest-source-file
           "(testing harness)")))
    (should entry)
    (should (eq (plist-get entry :visibility) 'public))
    (should (equal (plist-get entry :exports)
                   '("testing-harness-run"
                     "testing-harness-check"
                     "testing-harness-runner-summary"
                     "testing-harness-runner-failed?")))
    (should source-file)
    (should
     (string-suffix-p
      "scheme/testing/harness.sld"
      source-file))
    (should (file-readable-p source-file))))

(ert-deftest consent-library-test-testing-registry-is-source-backed ()
  "Expose portable test discovery and selection through the runtime catalog."
  (let ((source-file
         (consent-library-test--manifest-source-file
          "(testing registry)")))
    (should source-file)
    (should
     (string-suffix-p
      "scheme/testing/registry.sld"
      source-file))
    (should (file-readable-p source-file))))

(ert-deftest consent-library-test-testing-plan-is-source-backed ()
  "Expose portable multi-program test plans through the runtime catalog."
  (let ((source-file
         (consent-library-test--manifest-source-file
          "(testing plan)")))
    (should source-file)
    (should
     (string-suffix-p
      "scheme/testing/plan.sld"
      source-file))
    (should (file-readable-p source-file))))

(ert-deftest consent-library-test-testing-runner-is-source-backed ()
  "Expose the portable developer-facing runner through the runtime catalog."
  (let ((source-file
         (consent-library-test--manifest-source-file
          "(testing runner)")))
    (should source-file)
    (should
     (string-suffix-p
      "scheme/testing/runner.sld"
      source-file))
    (should (file-readable-p source-file))))

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
       \"{\\\"choices\\\":[{\\\"message\\\":{\\\"content\\\":\\\"source\
 completion\\\"}}]}\")")
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

(ert-deftest
  consent-library-test-agent-primitive-backing-import-denied-by-default ()
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

(ert-deftest
  consent-library-test-primitive-library-requires-provider-declaration ()
  "Reject primitive registration that relies only on implementation ids."
  (let* ((context (consent--new-eval-context nil))
         (environment (consent-make-base-environment))
         (entry (list :name "(custom io)"
                      :source-kind 'primitive
                      :implementation-id 'agent-io)))
    (should-error
     (consent--register-manifest-implementation-library
      entry context environment)
     :type 'consent-eval-error)))

(defun consent-library-test--primitive-declaration-entry
    (&optional primitive-exports provider)
  "Return a parsed primitive declaration fixture catalog entry."
  (car
   (consent--library-catalog-parse-manifest
    (consent-read
     (format
      "(library-catalog
        (manifest-entry
         (schema-version 1)
         (kind primitive-library)
         (name (fixture reflect))
         (owner agent)
         (provider %s)
         (visibility public)
         (layer api)
         (source-kind primitive-library)
         (source (implementation-id fixture-reflect))
         (api-version (compat 0))
         (source-version runtime)
         (realization host-primitive)
         (exports (fixture-current))
         (primitive-exports
          %s)
         (dependencies ((library (scheme base))))
         (effects (reflection))
         (capabilities ())
         (provenance ((origin test)))
         (status implemented)
         (canonical #t)))"
      (or provider 'fixture-provider)
      (or primitive-exports
          "((name fixture-current)
            (primitive primitive-fixture-current)
            (arity 0 0)
            (effects (reflection))
            (capabilities ()))")))
    'primitive-declaration-fixture
    'primitive-declaration-fixture)))

(ert-deftest consent-library-test-agent-reflect-declares-provider-primitives ()
  "Represent `(agent reflect)' primitive exports as provider-owned metadata."
  (let* ((entry
          (consent--library-collection-manifest-entry "(agent reflect)"))
         (declaration
          (consent--primitive-library-declaration-for-entry entry))
         (current-budget
          (cl-find "current-budget"
                   (plist-get declaration :primitive-exports)
                   :key (lambda (export)
                          (plist-get export :name))
                   :test #'equal)))
    (should declaration)
    (should (eq (plist-get declaration :kind) 'primitive-library))
    (should (eq (plist-get declaration :visibility) 'public))
    (should (eq (plist-get declaration :layer) 'api))
    (should (eq (plist-get declaration :owner) 'agent))
    (should (eq (plist-get declaration :provider) 'host-adapter))
    (should current-budget)
    (should (eq (plist-get current-budget :primitive)
                'primitive-current-budget))
    (should (equal (plist-get current-budget :arity) '(0 0)))
    (should (equal (plist-get current-budget :effects)
                   '(reflection)))
    (should (equal (plist-get current-budget :capabilities) '()))))

(ert-deftest consent-library-test-agent-reflect-materializes-from-declaration
  ()
  "Use provider declarations and the reflect implementation resolver."
  (require 'consent-reflect)
  (let* ((context (consent--new-eval-context nil))
         (environment (consent-make-base-environment))
         (entry
          (consent--library-collection-manifest-entry "(agent reflect)"))
         (resolver (symbol-function 'consent-reflect-primitive-implementation))
         (resolved nil))
    (cl-letf (((symbol-function 'consent-reflect-primitive-implementation)
               (lambda (primitive)
                 (push primitive resolved)
                 (funcall resolver primitive))))
      (consent--register-manifest-implementation-library
       entry context environment))
    (let* ((library
            (gethash "(agent reflect)"
                     (consent--eval-context-libraries context)))
           (exports
            (mapcar #'consent--library-binding-name
                    (consent--library-exports library))))
      (should library)
      (should (member "current-budget" exports))
      (should (member "library-info" exports))
      (should (memq 'primitive-current-budget resolved)))))

(ert-deftest consent-library-test-agent-reflect-retires-legacy-primitive-specs
  ()
  "Do not keep a second source of truth for `(agent reflect)' primitives."
  (require 'consent-reflect)
  (should-not (fboundp 'consent-reflect-primitive-specs)))

(ert-deftest consent-library-test-primitive-libraries-declare-provider-exports
  ()
  "All built-in primitive libraries should be declared by their providers."
  (let (missing)
    (dolist (entry (consent--library-collection-manifest-entries))
      (when (eq (plist-get entry :kind) 'primitive-library)
        (unless (and (plist-get entry :implementation-resolver)
                     (plist-get entry :primitive-exports)
                     (consent--primitive-library-declaration-for-entry entry))
          (push (plist-get entry :name) missing))))
    (should (equal (nreverse missing) nil))))

(ert-deftest consent-library-test-manifest-file-primitives-keep-cps-dispatch ()
  "Keep manifest-routed file callbacks on the evaluator's CPS primitive path."
  (let* ((entry (consent--library-collection-manifest-entry "(scheme file)"))
         (specs (consent--manifest-primitive-implementation-specs entry))
         (spec (cl-find "call-with-input-file" specs
                        :key #'car
                        :test #'equal)))
    (should (eq (cadr spec) 'consent--primitive-call-with-input-file)))
  (should
   (equal
    (consent-library-test--external/options
     "(import (scheme base) (scheme file))
      (call-with-input-file
       \"fixtures/r7rs/conformance-cases.scm\"
       (lambda (port) (char? (read-char port))))"
     (consent-library-test--file-grant-options))
    "#t")))

(ert-deftest consent-library-test-primitive-declaration-registry-conflicts ()
  "Validate deterministic duplicate and conflicting provider declarations."
  (let ((consent--primitive-library-provider-declarations nil))
    (let ((entry (consent-library-test--primitive-declaration-entry)))
      (should (consent--primitive-library-register-declaration entry))
      (should (consent--primitive-library-register-declaration entry))
      (should-error
       (consent--primitive-library-register-declaration
        (consent-library-test--primitive-declaration-entry
         "((name fixture-current)
           (primitive primitive-fixture-current)
           (arity 0 0)
           (effects (state-read reflection))
           (capabilities ()))"))
       :type 'consent-eval-error)
      (should-error
       (consent--primitive-library-register-declaration
        (consent-library-test--primitive-declaration-entry nil
          'other-provider))
       :type 'consent-eval-error)
      (should
       (consent--primitive-library-register-declaration
        (consent-library-test--primitive-declaration-entry
         "((name fixture-current)
           (primitive primitive-fixture-current)
           (arity 0 0)
           (effects (state-read reflection))
           (capabilities ()))")
        t))
      (should
       (consent--primitive-library-remove-declaration
        "(fixture reflect)"
        'fixture-provider))
      (should-not
       (consent--primitive-library-declaration-for-name
        "(fixture reflect)")))))

(ert-deftest consent-library-test-primitive-declaration-validates-metadata ()
  "Reject primitive declarations that omit required export metadata."
  (should-error
   (consent--primitive-library-validate-declaration
    (consent-library-test--primitive-declaration-entry
     "((name fixture-current)
       (primitive primitive-fixture-current)
       (effects (reflection))
       (capabilities ()))"))
   :type 'consent-eval-error)
  (should-error
   (consent--primitive-library-validate-declaration
    (consent-library-test--primitive-declaration-entry
     "((name fixture-current)
       (primitive primitive-fixture-current)
       (arity 0 0)
       (capabilities ()))"))
   :type 'consent-eval-error)
  (should-error
   (consent--primitive-library-validate-declaration
    (consent-library-test--primitive-declaration-entry
     "((name fixture-current)
       (primitive primitive-fixture-current)
       (arity 0 0)
       (effects (reflection))
       (capabilities ()))
      ((name fixture-current)
       (primitive primitive-fixture-current-again)
       (arity 0 0)
       (effects (reflection))
       (capabilities ()))"))
   :type 'consent-eval-error))

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
  (should-not
   (consent--library-collection-manifest-entry
    "(scheme char primitive)")))

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
  (let ((entry (consent--library-collection-manifest-entry "(scheme cxr)")))
    (should (eq (plist-get entry :kind) 'library))
    (should (eq (plist-get entry :source-kind) 'portable-source))
    (should (equal (plist-get entry :source-file) "consent/cxr.sld"))
    (should-not (plist-get entry :primitive-exports)))
  (let ((entry (consent--library-collection-manifest-entry "(scheme char)")))
    (should (eq (plist-get entry :kind) 'library))
    (should (eq (plist-get entry :source-kind) 'portable-source))
    (should (equal (plist-get entry :source-file) "consent/char.sld"))
    (should-not (plist-get entry :primitive-overlay-library))
    (should-not (plist-get entry :primitive-exports)))
  (should-not
   (consent--library-collection-manifest-entry
    "(scheme char primitive)")))

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

(defconst consent-library-test--stdlib-external-reference-entries
  '("(stdlib json)"
    "(srfi 0)"
    "(srfi 16)"
    "(stdlib srfi-reference)"
    "(stdlib srfi-libraries)"
    "(stdlib and-let-star)"
    "(stdlib list)"
    "(stdlib generator)"
    "(stdlib testing)"
    "(stdlib random-bits)"
    "(stdlib random-distributions)"
    "(stdlib property-testing)"
    "(stdlib lightweight-testing)"
    "(stdlib receive)"
    "(stdlib assume)"
    "(stdlib comparator)"
    "(stdlib rbtree)"
    "(stdlib mapping)")
  "Canonical stdlib entries whose external specs are vendored locally.")

(defun consent-library-test--reference-documents (documents)
  "Return DOCUMENTS as a list of local reference document records."
  (if (consent--library-catalog-manifest-field documents "path" nil)
      (list documents)
    (consent--proper-list-elements documents "local reference documents")))

(ert-deftest
  consent-library-test-stdlib-manifests-link-local-reference-documents ()
  "Link external stdlib entries to manifest-relative local references."
  (let (missing)
    (dolist (key consent-library-test--stdlib-external-reference-entries)
      (let* ((entry (consent--library-collection-manifest-entry key))
             (provenance (plist-get entry :provenance))
             (documents
              (and provenance
                   (consent--library-catalog-manifest-field
                    provenance "local-reference-documents" nil))))
        (if (not documents)
            (push (format "%s missing local-reference-documents" key)
                  missing)
          (dolist (document
                   (consent-library-test--reference-documents documents))
            (let ((path (consent--library-catalog-manifest-field
                         document "path" nil)))
              (cond
               ((not path)
                (push (format "%s reference document lacks path" key)
                      missing))
               ((file-name-absolute-p path)
                (push (format "%s reference file is absolute: %s" key path)
                      missing))
               ((string-match-p "\\`\\(?:docs\\|scheme\\)/" path)
                (push (format "%s reference file is repo-relative: %s" key
                  path)
                      missing))
               ((not (file-exists-p
                      (expand-file-name
                       path consent-library-test--stdlib-manifest-directory)))
                (push (format "%s missing reference file %s" key path)
                      missing))))))))
    (should-not (nreverse missing))))

(defun consent-library-test--file-sha256 (path)
  "Return the hexadecimal SHA-256 digest of PATH's literal bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (secure-hash 'sha256 (current-buffer))))

(ert-deftest consent-library-test-srfi-reference-markdown-inventory ()
  "Keep generated SRFI Markdown licensed, hashed, and paired with source HTML."
  (let* ((reference-directory
          (expand-file-name "reference"
                            consent-library-test--stdlib-manifest-directory))
         (inventory-path (expand-file-name "README.md" reference-directory))
         (inventory
          (with-temp-buffer
            (insert-file-contents inventory-path)
            (buffer-string)))
         (html-paths
          (directory-files-recursively reference-directory
                                       "srfi-[0-9]+\\.html\\'")))
    (should html-paths)
    (dolist (html-path html-paths)
      (let* ((markdown-path (concat (file-name-sans-extension html-path)
        ".md"))
             (relative-html (file-relative-name html-path reference-directory))
             (relative-markdown
              (file-relative-name markdown-path reference-directory))
             (html-hash (consent-library-test--file-sha256 html-path))
             (markdown-hash
              (and (file-exists-p markdown-path)
                   (consent-library-test--file-sha256 markdown-path))))
        (should (file-exists-p markdown-path))
        (with-temp-buffer
          (insert-file-contents markdown-path)
          (should (search-forward
                   (concat "<!-- SPDX-" "License-Identifier: MIT -->") nil t))
          (should (search-forward
                   (concat "<!-- SPDX-"
                           "FileCopyrightText: SRFI document authors -->")
                   nil t))
          (should (search-forward "Permission is hereby granted" nil t)))
        (should
         (string-match-p
          (regexp-quote
           (format "`%s` | `%s` | `%s` | `%s`"
                   relative-markdown markdown-hash relative-html html-hash))
          inventory))))))

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

(ert-deftest consent-library-test-pure-alias-manifest-inherits-target-exports
  ()
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
        (index (consent--library-collection-manifest-entry
          "(manifest index)")))
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
    (should-not (consent--library-collection-manifest-entry "(srfi manifest)"))

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

(ert-deftest consent-library-test-ad-hoc-catalog-alias-imports ()
  "Resolve imports from the same catalog graph exposed by reflection."
  (unwind-protect
      (progn
        (consent--library-catalog-add-manifest
         'resolver-alias-fixture
         (consent-read
          "(library-catalog
             (manifest-index-entry
              (schema-version 1)
              (kind library-alias)
              (name (project base-alias))
              (target (scheme base))
              (derived-from resolver-alias-fixture)
              (visibility public)
              (layer alias)
              (category project)
              (source-kind alias)
              (api-version (inherits (scheme base)))
              (source-version runtime)
              (realization alias)
              (status available)
              (canonical #f)))"))
        (should
         (equal
          (consent-library-test--external
           "(import (project base-alias))
            (+ 19 23)")
          "42")))
    (consent--library-catalog-remove-manifest 'resolver-alias-fixture)))

(ert-deftest
  consent-library-test-load-light-avoids-agent-implementation-requires ()
  "Keep manifest aggregation from requiring agent implementations at module\
 load."
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

(ert-deftest consent-library-test-data-collection-is-public-source-root ()
  "Discover the public data collection from the root manifest."
  (let ((spec
         (cl-find-if
          (lambda (candidate)
            (eq (plist-get candidate :collection) 'data))
          (consent--library-collection-manifest-specs))))
    (should spec)
    (should (equal (plist-get spec :key) "(data manifest)"))
    (should (equal (plist-get spec :manifest-file) "data/manifest.sld"))
    (should (equal (plist-get spec :source-root) "data/"))
    (should (equal (plist-get spec :variable) "data-library-manifest"))))

(ert-deftest consent-library-test-data-source-libraries-are-file-backed ()
  "Discover source files and exports for public data libraries."
  (let* ((specs (consent-data-source-library-specs))
         (manifest
          (consent-library-test--standard-source-spec
           "(data manifest)" specs))
         (avl-tree
          (consent-library-test--standard-source-spec
           "(data avl-tree)" specs))
         (avl-mapping
          (consent-library-test--standard-source-spec
           "(data mapping avl)" specs))
         (transient-map
          (consent-library-test--standard-source-spec
           "(data transient-map)" specs))
         (source-file (and manifest (plist-get manifest :source-file))))
    (should manifest)
    (should avl-tree)
    (should avl-mapping)
    (should transient-map)
    (should-not
     (consent-library-test--standard-source-spec
      "(data avl-tree implementation)" specs))
    (should (equal (plist-get manifest :exports)
                   '("data-library-manifest"
                     "data-library-manifest-ref")))
    (should (member "avl-tree-delete" (plist-get avl-tree :exports)))
    (should (member "avl-tree-ref/key" (plist-get avl-tree :exports)))
    (should (member "avl-tree-split" (plist-get avl-tree :exports)))
    (should (member "avl-tree-valid?" (plist-get avl-tree :exports)))
    (should (equal (plist-get avl-mapping :exports)
                   '("avl-mapping"
                     "avl-mapping-unfold"
                     "alist->avl-mapping")))
    (should (member "transient-map-persistent!"
                    (plist-get transient-map :exports)))
    (should (member "transient-map-reset!"
                    (plist-get transient-map :exports)))
    (should (string-suffix-p "scheme/data/manifest.sld" source-file))
    (should (file-readable-p source-file))
    (should
     (string-suffix-p
      "scheme/data/avl-tree.sld"
      (plist-get avl-tree :source-file)))
    (should
     (string-suffix-p
      "scheme/data/mapping/avl.sld"
      (plist-get avl-mapping :source-file)))
    (should
     (string-suffix-p
      "scheme/data/transient-map.sld"
      (plist-get transient-map :source-file)))))

(ert-deftest consent-library-test-data-manifests-link-user-specifications ()
  "Link public data structures to collection-local user specifications."
  (let (missing)
    (dolist (key '("(data avl-tree)"
                   "(data mapping avl)"
                   "(data transient-map)"))
      (let* ((entry (consent--library-collection-manifest-entry key))
             (provenance (plist-get entry :provenance))
             (documents
              (and provenance
                   (consent--library-catalog-manifest-field
                    provenance "local-reference-documents" nil))))
        (if (not documents)
            (push (format "%s missing local-reference-documents" key)
                  missing)
          (dolist (document
                   (consent-library-test--reference-documents documents))
            (let ((path (consent--library-catalog-manifest-field
                         document "path" nil))
                  (role (consent--library-catalog-manifest-field
                         document "role" nil))
                  (source (consent--library-catalog-manifest-field
                           document "source" nil)))
              (cond
               ((not path)
                (push (format "%s reference document lacks path" key)
                      missing))
               ((file-name-absolute-p path)
                (push (format "%s reference file is absolute: %s" key path)
                      missing))
               ((string-match-p "\\`\\(?:docs\\|scheme\\)/" path)
                (push (format "%s reference file is repo-relative: %s"
                              key path)
                      missing))
               ((not (file-exists-p
                      (expand-file-name
                       path consent-library-test--data-manifest-directory)))
                (push (format "%s missing reference file %s" key path)
                      missing)))
              (unless (and (consent-symbol-p role)
                           (equal (consent-symbol-name role) "specification"))
                (push (format "%s reference role is %S" key role) missing))
              (unless (and (consent-symbol-p source)
                           (equal (consent-symbol-name source) "consent"))
                (push (format "%s reference source is %S" key source)
                      missing)))))))
    (should-not (nreverse missing))))

(ert-deftest consent-library-test-data-avl-tree-imports ()
  "Import and use the public persistent AVL tree through the bootstrap."
  (should
   (equal
    (consent-library-test--external
     "(import (data avl-tree))
      (let* ((tree (avl-tree-set (make-avl-tree <) 2 'two))
             (next (avl-tree-set tree 1 'one)))
        (list (avl-tree-ref next 1)
              (avl-tree-size next)
              (avl-tree->alist tree)))")
    "(one 2 ((2 . two)))")))

(ert-deftest consent-library-test-data-avl-mapping-imports ()
  "Use AVL constructors through the standard Mapping interface."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base)
              (scheme comparator)
              (scheme mapping)
              (data mapping avl))
      (define comparator
        (make-comparator integer? = < number-hash))
      (let* ((mapping (avl-mapping comparator 2 'two 1 'one))
             (next (mapping-set mapping 3 'three)))
        (list (mapping? next)
              (mapping->alist next)
              (mapping->alist mapping)))")
    "(#t ((1 . one) (2 . two) (3 . three)) ((1 . one) (2 . two)))")))

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

(ert-deftest consent-library-test-source-cache-reuses-and-invalidates-parse ()
  "Reuse an unchanged parsed source library and notice file replacement."
  (let* ((root (make-temp-file "consent-source-cache-" t))
         (entry (consent-library-test--cached-source-entry root))
         (original-read-all (symbol-function 'consent-read-all))
         (parse-count 0))
    (unwind-protect
        (progn
          (consent-library-test--write-cached-source root 1)
          (consent--source-library-cache-reset)
          (cl-letf
              (((symbol-function 'consent-read-all)
                (lambda (source &optional options)
                  (when (string-match-p
                         "define-library (test cached-source)"
                         source)
                    (setq parse-count (1+ parse-count)))
                  (funcall original-read-all source options))))
            (consent-library-test--register-cached-source entry)
            (consent-library-test--register-cached-source entry)
            (should (= parse-count 1))
            (consent-library-test--write-cached-source root 12345)
            (let* ((registered
                    (consent-library-test--register-cached-source entry))
                   (library (cdr registered)))
              (should (= parse-count 2))
              (should
               (equal
                (consent-value->external
                 (consent-library-test--cached-source-value
                  library "value"))
                "12345")))))
      (consent--source-library-cache-reset)
      (delete-directory root t))))

(ert-deftest consent-library-test-source-cache-isolates-mutable-datums ()
  "Copy cached mutable literals before evaluating each source library."
  (let* ((root (make-temp-file "consent-source-cache-mutable-" t))
         (entry (consent-library-test--cached-source-entry root)))
    (unwind-protect
        (progn
          (consent-library-test--write-cached-source root 1)
          (consent--source-library-cache-reset)
          (let* ((left
                  (cdr
                   (consent-library-test--register-cached-source entry)))
                 (right
                  (cdr
                   (consent-library-test--register-cached-source entry)))
                 (left-text
                  (consent-library-test--cached-source-value left "text"))
                 (right-text
                  (consent-library-test--cached-source-value right "text"))
                 (left-items
                  (consent-library-test--cached-source-value left "items"))
                 (right-items
                  (consent-library-test--cached-source-value right "items"))
                 (left-bytes
                  (consent-library-test--cached-source-value left "bytes"))
                 (right-bytes
                  (consent-library-test--cached-source-value right "bytes")))
            (should-not (eq left-text right-text))
            (should-not (eq left-items right-items))
            (should-not (eq left-bytes right-bytes))
            (aset left-text 0 ?X)
            (aset left-items 0 consent-false)
            (aset (consent-bytevector-bytes left-bytes) 0 9)
            (should (equal right-text "fresh"))
            (should
             (equal (consent-value->external right-items) "#(1 2)"))
            (should
             (equal (consent-value->external right-bytes) "#u8(3 4)"))))
      (consent--source-library-cache-reset)
      (delete-directory root t))))

(ert-deftest consent-library-test-shared-immutable-source-is-explicit ()
  "Share only manifest-trusted immutable data in the process symbol domain."
  (let* ((root (make-temp-file "consent-shared-source-" t))
         (entry
          (consent-library-test--cached-source-entry
           root 'shared-immutable-data 'internal-runtime))
         (public-entry
          (consent-library-test--cached-source-entry
           root 'shared-immutable-data 'public))
         (ordinary-entry
          (consent-library-test--cached-source-entry
           root 'portable-source 'internal-runtime)))
    (unwind-protect
        (progn
          (consent-library-test--write-cached-source root 1)
          (consent--source-library-cache-reset)
          (let ((direct-left
                 (cdr
                  (consent-library-test--register-cached-source entry)))
                (direct-right
                 (cdr
                  (consent-library-test--register-cached-source entry))))
            (should-not (eq direct-left direct-right)))
          (let ((consent--source-library-internal-imports-allowed t))
            (let* ((left
                    (cdr
                     (consent-library-test--register-cached-source entry)))
                   (right
                    (cdr
                     (consent-library-test--register-cached-source entry)))
                   (public-left
                    (cdr
                     (consent-library-test--register-cached-source
                      public-entry)))
                   (public-right
                    (cdr
                     (consent-library-test--register-cached-source
                      public-entry)))
                   (ordinary-left
                    (cdr
                     (consent-library-test--register-cached-source
                      ordinary-entry)))
                   (ordinary-right
                    (cdr
                     (consent-library-test--register-cached-source
                      ordinary-entry)))
                   (left-table (consent--make-symbol-table))
                   (right-table (consent--make-symbol-table))
                   (isolated-left
                    (cdr
                     (consent-library-test--register-cached-source
                      entry (list :symbol-table left-table))))
                   (isolated-right
                    (cdr
                     (consent-library-test--register-cached-source
                      entry (list :symbol-table right-table))))
                   (left-name (car (consent--library-name isolated-left)))
                   (right-name (car (consent--library-name isolated-right))))
              (should (eq left right))
              (should-not (eq public-left public-right))
              (should-not (eq ordinary-left ordinary-right))
              (consent--library-catalog-invalidate)
              (should
               (eq left
                   (cdr
                    (consent-library-test--register-cached-source entry))))
              (should-not (eq left isolated-left))
              (should-not (eq isolated-left isolated-right))
              (should
               (eq left-name
                   (gethash
                    "test" (consent--symbol-table-entries left-table))))
              (should
               (eq right-name
                   (gethash
                    "test" (consent--symbol-table-entries right-table))))
              (should-not (eq left-name right-name))
              (consent-library-test--write-cached-source root 12345)
              (let ((replacement
                     (cdr
                      (consent-library-test--register-cached-source entry))))
                (should-not (eq left replacement))
                (should
                 (equal
                  (consent-value->external
                   (consent-library-test--cached-source-value
                    replacement "value"))
                  "12345"))))))
      (consent--source-library-cache-reset)
      (delete-directory root t))))

(ert-deftest consent-library-test-shared-cache-preserves-budget-costs ()
  "Keep source-library aggregate logical costs equal on cache hits."
  (let* ((root (make-temp-file "consent-shared-budget-cost-" t))
         (entry
          (consent-library-test--cached-source-entry
           root 'shared-immutable-data 'internal-runtime)))
    (unwind-protect
        (progn
          (consent-library-test--write-cached-source root 1)
          (consent--source-library-cache-reset)
          (let ((consent--source-library-internal-imports-allowed t))
            (let* ((cold
                    (consent-library-test--register-cached-source entry))
                   (warm
                    (consent-library-test--register-cached-source entry)))
              (should (eq (cdr cold) (cdr warm)))
              (should (> (consent--eval-context-steps (car cold)) 0))
              (should (> (consent--eval-context-value-nodes (car cold)) 0))
              (should
               (= (consent--eval-context-steps (car cold))
                  (consent--eval-context-steps (car warm))))
              (should
               (= (consent--eval-context-value-nodes (car cold))
                  (consent--eval-context-value-nodes (car warm)))))))
      (consent--source-library-cache-reset)
      (delete-directory root t))))

(ert-deftest consent-library-test-shared-cache-enforces-value-node-budget ()
  "Enforce a tight value-node budget on shared source cache hits."
  (let* ((root (make-temp-file "consent-shared-value-budget-" t))
         (entry
          (consent-library-test--cached-source-entry
           root 'shared-immutable-data 'internal-runtime)))
    (unwind-protect
        (progn
          (consent-library-test--write-cached-source root 1)
          (consent--source-library-cache-reset)
          (let ((consent--source-library-internal-imports-allowed t))
            (let* ((cold
                    (consent-library-test--register-cached-source entry))
                   (value-node-cost
                    (consent--eval-context-value-nodes (car cold))))
              (should (> value-node-cost 0))
              (should-error
               (consent-library-test--register-cached-source
                entry
                (list :max-value-nodes (1- value-node-cost)))
               :type 'consent-budget-error))))
      (consent--source-library-cache-reset)
      (delete-directory root t))))

(ert-deftest consent-library-test-shared-cache-enforces-step-budget ()
  "Enforce a tight step budget on shared source cache hits."
  (let* ((root (make-temp-file "consent-shared-step-budget-" t))
         (entry
          (consent-library-test--cached-source-entry
           root 'shared-immutable-data 'internal-runtime)))
    (unwind-protect
        (progn
          (consent-library-test--write-cached-source root 1)
          (consent--source-library-cache-reset)
          (let ((consent--source-library-internal-imports-allowed t))
            (let* ((cold
                    (consent-library-test--register-cached-source entry))
                   (step-cost
                    (consent--eval-context-steps (car cold))))
              (should (> step-cost 0))
              (should-error
               (consent-library-test--register-cached-source
                entry
                (list :max-steps (1- step-cost)))
               :type 'consent-budget-error))))
      (consent--source-library-cache-reset)
      (delete-directory root t))))

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

(ert-deftest consent-library-test-srfi-0-cond-expand-imports ()
  "Import SRFI 0 aliases and exercise the R7RS `cond-expand' shim."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 0))
      (cond-expand
        (srfi-0 'srfi-0-imported)
        (else 'missing))")
    "srfi-0-imported"))
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture srfi-0-cond-expand)
        (cond-expand
          ((and srfi-0 (library (srfi srfi-0)))
           (export answer)
           (import (scheme base))
           (begin (define answer 'srfi-0-library-feature)))
          (else
           (export answer)
           (import (scheme base))
           (begin (define answer 'missing)))))
      (import (scheme base)
              (srfi srfi-0)
              (consent fixture srfi-0-cond-expand))
      answer")
    "srfi-0-library-feature")))

(ert-deftest consent-library-test-srfi-0-missing-export-diagnostic ()
  "Report missing SRFI 0 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 0) missing-cond-expand-binding))
            missing-cond-expand-binding")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-cond-expand-binding")
      (error-message-string error)))))

(ert-deftest consent-library-test-srfi-261-reference-alias-imports ()
  "Import SRFI 261 reference aliases without inventing bindings."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 261))
      'srfi-261-imported")
    "srfi-261-imported"))
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture srfi-261-reference)
        (cond-expand
          ((library (srfi srfi-261))
           (export answer)
           (import (scheme base))
           (begin (define answer 'portable-srfi-reference)))
          (else
           (export answer)
           (import (scheme base))
           (begin (define answer 'missing)))))
      (import (scheme base)
              (srfi srfi-261)
              (consent fixture srfi-261-reference))
      answer")
    "portable-srfi-reference"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent reflect) (srfi 261))
      (library-bindings '(srfi 261))")
    "()")))

(ert-deftest consent-library-test-srfi-261-missing-export-diagnostic ()
  "Report missing SRFI 261 exports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 261) srfi-261-binding))
            srfi-261-binding")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "srfi-261-binding")
      (error-message-string error)))))

(ert-deftest
  consent-library-test-srfi-261-aliases-cover-supported-srfi-libraries ()
  "Require SRFI 261 portable aliases for every supported numeric SRFI."
  (let ((checked 0))
    (dolist (entry (consent--library-collection-manifest-entries))
      (let ((primary-key (plist-get entry :name)))
        (when (string-match "\\`(srfi \\([0-9]+\\))\\'" primary-key)
          (cl-incf checked)
          (let* ((number (match-string 1 primary-key))
                 (alias-key (format "(srfi srfi-%s)" number))
                 (target (or (plist-get entry :target) primary-key))
                 (alias-entry
                  (consent--library-collection-manifest-entry alias-key)))
            (should alias-entry)
            (should (eq (plist-get alias-entry :kind) 'library-alias))
                (should (equal (plist-get alias-entry :target) target))))))
    (should (> checked 0))))

(ert-deftest
  consent-library-test-srfi-261-pure-library-predicate-resolves-aliases ()
  "Classify SRFI 261 pure libraries by resolved implementation entries."
  (should
   (consent-library-test--srfi-261-pure-library-entry-p
    (consent--library-catalog-lookup "(srfi 1)")))
  (should-not
   (consent-library-test--srfi-261-pure-library-entry-p
    (consent--library-catalog-lookup "(srfi 0)")))
  (should-not
   (consent-library-test--srfi-261-pure-library-entry-p
    (consent--library-catalog-lookup "(srfi 97)"))))

(ert-deftest
  consent-library-test-srfi-261-omitted-srfis-are-not-plain-libraries ()
  "Require SRFI 261 omitted SRFIs to avoid plain binding-library manifests."
  (let ((checked 0))
    (dolist (number consent-library-test--srfi-261-omitted-srfis)
      (let* ((key (format "(srfi %d)" number))
             (entry (consent--library-catalog-lookup key)))
        (when entry
          (cl-incf checked)
          (should-not
           (consent-library-test--srfi-261-pure-library-entry-p entry)))))
    (should (> checked 0))))

(ert-deftest consent-library-test-srfi-97-library-reference-alias-imports ()
  "Import SRFI 97 library-reference aliases for supported SRFI libraries."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :1 lists))
      (iota 4)")
    "(0 1 2 3)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :1))
      (iota 3)")
    "(0 1 2)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :16 case-lambda))
      ((case-lambda
         ((x y) (+ x y)))
       2 5)")
    "7"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :16))
      ((case-lambda
         ((x y) (* x y)))
       2 5)")
    "10"))
  (should
   (equal
    (consent-library-test--external
     "(define-library (consent fixture srfi-97-library-reference)
        (cond-expand
          ((library (srfi :97 srfi-libraries))
           (export answer)
           (import (scheme base))
           (begin (define answer 'srfi-97-reference)))
          (else
           (export answer)
           (import (scheme base))
           (begin (define answer 'missing)))))
      (import (scheme base)
              (srfi 97)
              (srfi srfi-97)
              (srfi :97)
              (srfi :97 srfi-libraries)
              (consent fixture srfi-97-library-reference))
      answer")
    "srfi-97-reference"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (agent reflect) (srfi :97 srfi-libraries))
      (library-bindings '(srfi :97 srfi-libraries))")
    "()")))

(ert-deftest consent-library-test-srfi-97-missing-export-diagnostic ()
  "Report missing SRFI 97 alias exports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi :1 lists) missing-list-binding))
            missing-list-binding")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-list-binding")
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
                     '((srfi 8)
                       (srfi srfi-8)
                       (srfi :8)
                       (srfi :8 receive)))
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
                     '((srfi 2)
                       (srfi srfi-2)
                       (srfi :2)
                       (srfi :2 and-let*)))
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

(ert-deftest consent-library-test-srfi-64-imports-and-runs-tests ()
  "Import SRFI 64 aliases and exercise representative test-runner behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 64))
      (let ((runner (test-runner-null)))
        (test-with-runner runner
          (test-begin \"numbers\" 3)
          (test-assert \"truth\" #t)
          (test-eqv \"sum\" 4 (+ 2 2))
          (test-equal \"list\" '(a b) (list 'a 'b))
          (test-end \"numbers\"))
        (list (test-runner-pass-count runner)
              (test-runner-fail-count runner)
              (test-runner-skip-count runner)))")
    "(3 0 0)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-64))
      (let ((runner (test-runner-null)))
        (test-with-runner runner
          (test-begin \"control\")
          (test-skip \"skipped\")
          (test-assert \"kept\" #t)
          (test-assert \"skipped\" #f)
          (test-expect-fail \"known\")
          (test-assert \"known\" #f)
          (test-end \"control\"))
        (list (test-runner-pass-count runner)
              (test-runner-xfail-count runner)
              (test-runner-skip-count runner)))")
    "(1 1 1)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :64 testing))
      (let ((runner (test-runner-null)))
        (test-with-runner runner
          (test-begin \"legacy\" 1)
          (test-assert \"truth\" #t)
          (test-end \"legacy\"))
        (test-runner-pass-count runner))")
    "1"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :64))
      (test-runner? (test-runner-null))")
    "#t")))

(ert-deftest consent-library-test-srfi-64-records-result-properties ()
  "Expose SRFI 64 result properties and test names to custom runners."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 64))
      (let ((runner (test-runner-null))
            (properties '()))
        (test-runner-on-test-end!
         runner
         (lambda (active)
           (set! properties (cons (test-result-alist active)
                                  properties))))
        (test-with-runner runner
          (test-begin \"properties\")
          (test-equal \"named\" '(x y) (list 'x 'y))
          (test-end \"properties\"))
        (let ((result (car properties)))
          (list (cdr (assq 'test-name result))
                (cdr (assq 'expected-value result))
                (cdr (assq 'actual-value result))
                (cdr (assq 'result-kind result)))))")
    "(\"named\" (x y) (x y) pass)")))

(ert-deftest consent-library-test-srfi-64-missing-export-diagnostic ()
  "Report missing SRFI 64 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 64) missing-test-helper))
            missing-test-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-test-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-64 ()
  "Expose SRFI 64 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib testing)))
            (alias (stdlib-manifest-ref '(srfi 64)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-64)))
            (legacy-number-alias (stdlib-manifest-ref '(srfi :64)))
            (legacy-alias (stdlib-manifest-ref '(srfi :64 testing))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib testing))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (equal? (manifest-field entry 'aliases)
                     '((srfi 64)
                       (srfi srfi-64)
                       (srfi :64)
                       (srfi :64 testing)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme write))
                       (library (scheme read))
                       (library (scheme eval))
                       (library (scheme file))))
             (equal? (manifest-field alias 'target) '(stdlib testing))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib testing))
             (equal? (manifest-field legacy-number-alias 'target)
                     '(stdlib testing))
             (equal? (manifest-field legacy-alias 'target)
                     '(stdlib testing))))")
    "#t")))

(ert-deftest consent-library-test-srfi-27-imports-and-generates-random-values
  ()
  "Import SRFI 27 aliases and exercise representative random-source behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 27))
      (let* ((left (make-random-source))
             (right (make-random-source))
             (left-rand (random-source-make-integers left))
             (right-rand (random-source-make-integers right))
             (state (random-source-state-ref left))
             (left-values
              (list (left-rand 2) (left-rand 17) (left-rand 1000000)))
             (right-values
              (list (right-rand 2) (right-rand 17) (right-rand 1000000))))
        (random-source-state-set! left state)
        (list (random-source? left)
              (not (random-source? '(not a source)))
              (equal? left-values right-values)
              (equal? (list (left-rand 2) (left-rand 17)
                            (left-rand 1000000))
                      left-values)
              (car state)))")
    "(#t #t #t #t lecuyer-mrg32k3a)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-27))
      (let ((value ((random-source-make-integers (make-random-source)) 23)))
        (and (integer? value) (<= 0 value) (< value 23)))")
    "#t"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :27 random-bits))
      (let ((value ((random-source-make-reals (make-random-source)))))
        (and (real? value) (< 0 value) (< value 1)))")
    "#t"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :27))
      (random-source? default-random-source)")
    "#t")))

(ert-deftest consent-library-test-srfi-27-pseudo-randomize-is-deterministic ()
  "Derive deterministic independent SRFI 27 streams by index."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 27))
      (let ((left (make-random-source))
            (right (make-random-source)))
        (random-source-pseudo-randomize! left 3 5)
        (random-source-pseudo-randomize! right 3 5)
        (let ((left-rand (random-source-make-integers left))
              (right-rand (random-source-make-integers right)))
          (equal? (list (left-rand 1000) (left-rand 1000)
                        (left-rand 1000))
                  (list (right-rand 1000) (right-rand 1000)
                        (right-rand 1000)))))")
    "#t")))

(ert-deftest consent-library-test-srfi-27-randomize-requires-clock-grant ()
  "Keep SRFI 27 entropy randomization behind the clock capability."
  (let ((condition
         (should-error
          (consent-eval-source
           "(import (scheme base) (srfi 27))
            (random-source-randomize! (make-random-source))")
          :type 'consent-eval-error)))
    (should
     (string-match-p "no active clock grant covers request" (cadr
       condition)))))

(ert-deftest consent-library-test-srfi-27-randomize-uses-clock-grant ()
  "Allow SRFI 27 entropy randomization when a clock grant is present."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (consent capability) (srfi 27))
      (grant-capability!
       '(capability-grant
         (id srfi-27-clock-grant)
         (domain clock)
         (operations read)
         (scope (clock system))
         (expires (uses 1))))
      (let ((source (make-random-source)))
        (random-source-randomize! source)
        (random-source? source))")
    "#t")))

(ert-deftest consent-library-test-srfi-27-invalid-arguments-report-errors ()
  "Report SRFI 27 range, unit, and state validation errors."
  (dolist (source
           '("(import (scheme base) (srfi 27)) (random-integer 0)"
             "(import (scheme base) (srfi 27))
              ((random-source-make-reals (make-random-source) 1))"
             "(import (scheme base) (srfi 27))
              (random-source-state-set! (make-random-source) '(bad state))"))
    (should-error
     (consent-library-test--external source)
     :type 'consent-eval-error)))

(ert-deftest consent-library-test-srfi-27-missing-export-diagnostic ()
  "Report missing SRFI 27 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 27) missing-random-helper))
            missing-random-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-random-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-random-distributions-imports ()
  "Import random distribution helpers and exercise representative behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib random-distributions))
      (let ((permutation (random-permutation 5))
            (exponential (random-exponential 2.0))
            (normal (random-normal 0.0 1.0)))
        (list (vector-length permutation)
              (and (real? exponential) (< 0 exponential))
              (real? normal)))")
    "(5 #t #t)")))

(ert-deftest
  consent-library-test-stdlib-manifest-documents-random-distributions ()
  "Expose random distribution helper status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib random-distributions))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name)
                     '(stdlib random-distributions))
             (equal? (manifest-field entry 'status)
                     'srfi-27-example-implementation)
             (equal? (manifest-field entry 'source)
                     '(path \"random-distributions.sld\"))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme inexact))
                       (library (stdlib random-bits))))
             (member 'random-source-make-permutations
                     (manifest-field entry 'exports))
             (member 'random-source-make-exponentials
                     (manifest-field entry 'exports))
             (member 'random-source-make-normals
                     (manifest-field entry 'exports))
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #f)))")
    "#t")))

(ert-deftest
  consent-library-test-srfi-194-imports-and-uses-random-data-generators ()
  "Import SRFI 194 aliases and exercise representative generator behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme complex) (stdlib generator) (srfi 194))
      (define (all-in-range? values low high)
        (let loop ((rest values))
          (cond
           ((null? rest) #t)
           ((and (>= (car rest) low) (< (car rest) high))
            (loop (cdr rest)))
           (else #f))))
      (let ((integers (generator->list
                       (make-random-integer-generator -3 7)
                       20))
            (category ((make-categorical-generator '#(0 5 0))))
            (bernoulli ((make-bernoulli-generator 1)))
            (point ((make-sphere-generator 2)))
            (sample (gsampling (generator 'x 'y))))
        (list (all-in-range? integers -3 7)
              category
              bernoulli
              (vector-length point)
              (list (sample) (sample) (eof-object? (sample)))))")
    "(#t 1 1 3 (x y #t))"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme complex) (srfi srfi-194))
      (let ((z ((make-random-rectangular-generator -1.0 1.0 -2.0 2.0)))
            (g (make-geometric-generator 1)))
        (list (complex? z) (g)))")
    "(#t 1)")))

(ert-deftest consent-library-test-srfi-194-missing-export-diagnostic ()
  "Report missing SRFI 194 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 194) missing-random-data-helper))
            missing-random-data-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-random-data-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-194 ()
  "Expose SRFI 194 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib random-data-generators)))
            (alias (stdlib-manifest-ref '(srfi 194)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-194))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name)
                     '(stdlib random-data-generators))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (member \"srfi-194-test.scm\"
                     (manifest-subfield entry 'provenance
                                        'upstream-test-files))
             (member \"zipf-test.scm\"
                     (manifest-subfield entry 'provenance
                                        'upstream-test-files))
             (member \"sphere-test.scm\"
                     (manifest-subfield entry 'provenance
                                        'upstream-test-files))
             (member \"ellipsoid-test.scm\"
                     (manifest-subfield entry 'provenance
                                        'upstream-test-files))
             (equal?
              (cdr
               (assoc \"srfi-194-test.scm\"
                      (manifest-subfield entry 'provenance
                                         'upstream-test-blobs)))
              \"ffb1ec46ecf83853e1fd2b15d01a9f3ec250b41b\")
             (equal?
              (cdr
               (assoc \"zipf-test.scm\"
                      (manifest-subfield entry 'provenance
                                         'upstream-test-blobs)))
              \"509db74f571e3cf0c989f7674dc78425b5bb9876\")
             (equal?
              (cdr
               (assoc \"sphere-test.scm\"
                      (manifest-subfield entry 'provenance
                                         'upstream-test-blobs)))
              \"2de4be9e47f03e328e4e73b85dbb516c4a87ee1b\")
             (equal?
              (cdr
               (assoc \"ellipsoid-test.scm\"
                      (manifest-subfield entry 'provenance
                                         'upstream-test-blobs)))
              \"bc0d289cb1ab1f3da1c77b184124f86d7b18b7a6\")
             (equal? (manifest-field entry 'aliases)
                     '((srfi 194) (srfi srfi-194)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme case-lambda))
                       (library (scheme inexact))
                       (library (scheme complex))
                       (library (stdlib random-bits))
                       (library (stdlib generator))))
             (member 'make-random-integer-generator
                     (manifest-field entry 'exports))
             (member 'make-categorical-generator
                     (manifest-field entry 'exports))
             (member 'make-sphere-generator
                     (manifest-field entry 'exports))
             (equal? (manifest-field alias 'target)
                     '(stdlib random-data-generators))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib random-data-generators))))")
    "#t")))

(ert-deftest consent-library-test-srfi-252-imports-and-runs-property-tests ()
  "Import SRFI 252 aliases and exercise representative property behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 64) (srfi 252))
      (let ((runner (test-runner-null)))
        (test-with-runner runner
          (test-begin \"properties\" 4)
          (test-property boolean? (list (boolean-generator)) 4)
          (test-end \"properties\"))
        (list (test-runner-pass-count runner)
              (test-runner-fail-count runner)
              (test-runner-skip-count runner)))")
    "(4 0 0)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (stdlib generator) (srfi srfi-252))
      (let ((pairs (pair-generator-of (generator 'a 'b)
                                      (generator 1 2))))
        (list (pairs) (pairs)))")
    "((a . 1) (b . 2))")))

(ert-deftest consent-library-test-srfi-252-missing-export-diagnostic ()
  "Report missing SRFI 252 imports through the resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 252) missing-property-helper))
            missing-property-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-property-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-252 ()
  "Expose SRFI 252 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib property-testing)))
            (alias (stdlib-manifest-ref '(srfi 252)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-252))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name)
                     '(stdlib property-testing))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (equal? (manifest-subfield entry 'provenance
                                        'local-reference-documents)
                     '((path \"reference/srfi-252/srfi-252.md\")
                       (role specification)
                       (source srfi)))
             (member \"property-test-tests.scm\"
                     (manifest-subfield entry 'provenance
                                        'upstream-test-files))
             (equal?
              (cdr
               (assoc \"property-test.sld\"
                      (manifest-subfield entry 'provenance
                                         'upstream-source-blobs)))
              \"611b12da5564cd379d1c9dda877a8507fa824f41\")
             (equal?
              (cdr
               (assoc \"property-test-tests.scm\"
                      (manifest-subfield entry 'provenance
                                         'upstream-test-blobs)))
              \"5a37ecee814e5a9b9eaf2478abd436ada2416eaa\")
             (member '(library (srfi 143))
                     (manifest-subfield entry 'provenance
                                        'optional-dependencies))
             (member '(library (srfi 144))
                     (manifest-subfield entry 'provenance
                                        'optional-dependencies))
             (equal? (manifest-field entry 'aliases)
                     '((srfi 252) (srfi srfi-252)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme case-lambda))
                       (library (scheme complex))
                       (library (stdlib list))
                       (library (stdlib testing))
                       (library (stdlib generator))
                       (library (stdlib random-data-generators))))
             (member 'test-property
                     (manifest-field entry 'exports))
             (member 'pair-generator-of
                     (manifest-field entry 'exports))
             (member 'boolean-generator
                     (manifest-field entry 'exports))
             (equal? (manifest-field alias 'target)
                     '(stdlib property-testing))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib property-testing))))")
    "#t")))

(ert-deftest consent-library-test-srfi-42-eager-comprehensions-imports ()
  "Import SRFI 42 aliases and exercise representative comprehensions."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 42))
      (list (list-ec (:range i 5) (* i i))
            (list-ec (:parallel (:range i 1 10)
                                (:list x '(a b c)))
                     (list i x))
            (any?-ec (:range i 2 3) (even? i)))")
    "((0 1 4 9 16) ((1 a) (2 b) (3 c)) #t)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi srfi-42))
      (sum-ec (:range i 4) i)")
    "6"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :42 eager-comprehensions))
      (list-ec (:list x '(a b)) x)")
    "(a b)")))

(ert-deftest consent-library-test-srfi-42-missing-export-diagnostic ()
  "Report missing SRFI 42 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 42) missing-eager-helper))
            missing-eager-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-eager-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-42 ()
  "Expose SRFI 42 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib eager-comprehensions)))
            (alias (stdlib-manifest-ref '(srfi 42)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-42)))
            (legacy-alias
             (stdlib-manifest-ref '(srfi :42 eager-comprehensions))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name)
                     '(stdlib eager-comprehensions))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'upstream-status)
                     'final)
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (equal? (manifest-subfield entry 'provenance
                                        'local-reference-documents)
                     '((path \"reference/srfi-42/srfi-42.md\")
                       (role specification)
                       (source srfi)))
             (member
              '(adapted-tests
                (file \"tests/scheme/stdlib-eager-comprehensions-test.scm\")
                (file
 \"tests/scheme/stdlib-eager-comprehensions-upstream-test.scm\"))
              (manifest-subfield entry 'provenance 'local-patches))
             (equal? (manifest-field entry 'aliases)
                     '((srfi 42)
                       (srfi srfi-42)
                       (srfi :42)
                       (srfi :42 eager-comprehensions)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme read))))
             (member 'list-ec (manifest-field entry 'exports))
             (member ':range (manifest-field entry 'exports))
             (member ':-dispatch-set! (manifest-field entry 'exports))
             (equal? (manifest-field alias 'target)
                     '(stdlib eager-comprehensions))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib eager-comprehensions))
             (equal? (manifest-field legacy-alias 'target)
                     '(stdlib eager-comprehensions))))")
    "#t")))

(ert-deftest consent-library-test-srfi-78-lightweight-testing-imports ()
  "Import SRFI 78 aliases and exercise representative check behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 78))
      (check-set-mode! 'summary)
      (check-reset!)
      (check (+ 1 1) => 2)
      (let ((first (check-passed? 1)))
        (check (+ 1 1) => 3)
        (list first (check-passed? 2)))")
    "(#t #f)"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi 42) (srfi srfi-78))
      (check-set-mode! 'summary)
      (check-reset!)
      (check-ec (:range i 5) (< i 5) => #t (i))
      (check-passed? 1)")
    "#t"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :78 lightweight-testing))
      (check-set-mode! 'summary)
      (check-reset!)
      (check (vector 1) (=> equal?) (vector 1))
      (check-passed? 1)")
    "#t"))
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi :78))
      (check-set-mode! 'off)
      (check-reset!)
      (check-passed? 0)")
    "#t")))

(ert-deftest consent-library-test-srfi-78-missing-export-diagnostic ()
  "Report missing SRFI 78 imports through the ordinary resolver diagnostic."
  (let ((error
         (should-error
          (consent-library-test--external
           "(import (scheme base)
                    (only (srfi 78) missing-lightweight-helper))
            missing-lightweight-helper")
          :type 'consent-eval-error)))
    (should
     (string-match-p
      (regexp-quote "only import name not found")
      (error-message-string error)))
    (should
     (string-match-p
      (regexp-quote "missing-lightweight-helper")
      (error-message-string error)))))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-78 ()
  "Expose SRFI 78 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib lightweight-testing)))
            (alias (stdlib-manifest-ref '(srfi 78)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-78)))
            (legacy-number-alias (stdlib-manifest-ref '(srfi :78)))
            (legacy-alias
             (stdlib-manifest-ref '(srfi :78 lightweight-testing))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name)
                     '(stdlib lightweight-testing))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'upstream-status)
                     'final)
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (equal? (manifest-subfield entry 'provenance
                                        'local-reference-documents)
                     '((path \"reference/srfi-78/srfi-78.md\")
                       (role specification)
                       (source srfi)))
             (member
              '(adapted-tests
                (file \"tests/scheme/stdlib-lightweight-testing-test.scm\")
                (file
 \"tests/scheme/stdlib-lightweight-testing-upstream-test.scm\"))
              (manifest-subfield entry 'provenance 'local-patches))
             (equal? (manifest-field entry 'aliases)
                     '((srfi 78)
                       (srfi srfi-78)
                       (srfi :78)
                       (srfi :78 lightweight-testing)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme cxr))
                       (library (scheme write))
                       (library (stdlib eager-comprehensions))))
             (member 'check (manifest-field entry 'exports))
             (member 'check-ec (manifest-field entry 'exports))
             (member 'check-report (manifest-field entry 'exports))
             (equal? (manifest-field alias 'target)
                     '(stdlib lightweight-testing))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib lightweight-testing))
             (equal? (manifest-field legacy-number-alias 'target)
                     '(stdlib lightweight-testing))
             (equal? (manifest-field legacy-alias 'target)
                     '(stdlib lightweight-testing))))")
    "#t")))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-27 ()
  "Expose SRFI 27 support status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib random-bits)))
            (alias (stdlib-manifest-ref '(srfi 27)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-27)))
            (legacy-number-alias (stdlib-manifest-ref '(srfi :27)))
            (legacy-alias (stdlib-manifest-ref '(srfi :27 random-bits))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'name) '(stdlib random-bits))
             (equal? (manifest-field entry 'status)
                     'vendored-adapted-implementation)
             (equal? (manifest-subfield entry 'provenance 'upstream-license)
                     \"MIT\")
             (equal? (manifest-subfield entry 'provenance 'local-license)
                     \"MIT\")
             (eq? (manifest-subfield entry 'provenance 'vendored?) #t)
             (member \"reference/conftest.scm\"
                     (manifest-subfield entry 'provenance
                                        'upstream-test-files))
             (equal?
              (cdr
               (assoc \"reference/conftest.scm\"
                      (manifest-subfield entry 'provenance
                                         'upstream-test-blobs)))
              \"5ceaaf0d8af4af29e8270ac52c00a69f80525cb5\")
             (equal? (manifest-field entry 'aliases)
                     '((srfi 27)
                       (srfi srfi-27)
                       (srfi :27)
                       (srfi :27 random-bits)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))
                       (library (scheme time))))
             (equal? (manifest-field alias 'target) '(stdlib random-bits))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib random-bits))
             (equal? (manifest-field legacy-number-alias 'target)
                     '(stdlib random-bits))
             (equal? (manifest-field legacy-alias 'target)
                     '(stdlib random-bits))))")
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
                       portable-host-suite compiled-self-host-corpus
                       imported-reference-corpus invalid-reference-corpus
                       json-lines json-text-sequences))))")
    "#t")))

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
    "((0 1 2 3) (0 1 4) ((a b) (c d)) (2 4) (11 22 33) 10 (4 6) #t #t 2\
 (\"bee\") (2 4) (1 3 5) (4 3 1 2))")))

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
                     '((scheme list)
                       (srfi 1)
                       (srfi srfi-1)
                       (srfi :1)
                       (srfi :1 lists)))
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
  "Import internal `(stdlib rbtree)' and exercise representative tree\
 behavior."
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
    "(#t 3 two ((1 . one) (2 . TWO) (3 . three) (4 . four)) (1 2 3 4) (one TWO\
 three four) 1 4 2 4 ((3 . three) (4 . four)) missing 2)")))

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
  "Keep `(scheme mapping)' and SRFI 146 aliases on the same ordered-map\
 surface."
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
              '((library (stdlib mapping implementation))))
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
             (equal? (manifest-field entry 'aliases)
                     '((srfi srfi-16)
                       (srfi :16)
                       (srfi :16 case-lambda)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme case-lambda))))
             (equal? (manifest-field portable-alias 'target)
                     '(scheme case-lambda))))")
    "#t")))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-0-shim ()
  "Expose SRFI 0 cond-expand shim status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(srfi 0)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-0))))
        (and (eq? (car entry) 'manifest-index-entry)
             (equal? (manifest-field entry 'status) 'built-in-shim)
             (equal? (manifest-field entry 'source) 'built-in-shim)
             (equal? (manifest-field entry 'exports) '(cond-expand))
             (equal? (manifest-field entry 'aliases)
                     '((srfi srfi-0)))
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))))
             (equal? (manifest-subfield entry 'provenance 'upstream-source-url)
                     \"https://srfi.schemers.org/srfi-0/\")
             (equal? (manifest-field entry 'target) '(scheme base))
             (equal? (manifest-field portable-alias 'target)
                     '(scheme base))))")
    "#t")))

(ert-deftest
  consent-library-test-stdlib-manifest-documents-srfi-261-reference-shim ()
  "Expose SRFI 261 reference-name shim status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib srfi-reference)))
            (alias (stdlib-manifest-ref '(srfi 261)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-261))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'status) 'built-in-shim)
             (equal? (manifest-field entry 'aliases)
                     '((srfi 261) (srfi srfi-261)))
             (equal? (manifest-field entry 'exports) '())
             (equal? (manifest-field entry 'dependencies)
                     '((library (scheme base))))
             (equal? (manifest-subfield entry 'provenance 'upstream-source-url)
                     \"https://srfi.schemers.org/srfi-261/\")
             (equal? (manifest-field alias 'status) 'built-in-shim)
             (equal? (manifest-field alias 'target)
                     '(stdlib srfi-reference))
             (equal? (manifest-field alias 'aliases)
                     '((srfi srfi-261)))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib srfi-reference))))")
    "#t")))

(ert-deftest consent-library-test-stdlib-manifest-documents-srfi-97-aliases ()
  "Expose SRFI 97 library-reference alias status through the stdlib manifest."
  (should
   (equal
    (consent-library-test--stdlib-manifest-external
     "(let ((entry (stdlib-manifest-ref '(stdlib srfi-libraries)))
            (alias (stdlib-manifest-ref '(srfi 97)))
            (portable-alias (stdlib-manifest-ref '(srfi srfi-97)))
            (legacy-number-alias (stdlib-manifest-ref '(srfi :97)))
            (legacy-alias (stdlib-manifest-ref '(srfi :97 srfi-libraries)))
            (legacy-list-number (stdlib-manifest-ref '(srfi :1)))
            (legacy-list (stdlib-manifest-ref '(srfi :1 lists)))
            (legacy-case-lambda
             (stdlib-manifest-ref '(srfi :16 case-lambda))))
        (and (eq? (car entry) 'manifest-entry)
             (equal? (manifest-field entry 'status) 'built-in-shim)
             (equal? (manifest-field entry 'aliases)
                     '((srfi 97)
                       (srfi srfi-97)
                       (srfi :97)
                       (srfi :97 srfi-libraries)))
             (equal? (manifest-field entry 'exports) '())
             (equal? (manifest-subfield entry 'provenance 'upstream-source-url)
                     \"https://srfi.schemers.org/srfi-97/\")
             (equal? (manifest-field alias 'target)
                     '(stdlib srfi-libraries))
             (equal? (manifest-field alias 'aliases)
                     '((srfi srfi-97)
                       (srfi :97)
                       (srfi :97 srfi-libraries)))
             (equal? (manifest-field portable-alias 'target)
                     '(stdlib srfi-libraries))
             (equal? (manifest-field legacy-number-alias 'target)
                     '(stdlib srfi-libraries))
             (equal? (manifest-field legacy-alias 'target)
                     '(stdlib srfi-libraries))
             (equal? (manifest-field legacy-list-number 'target)
                     '(stdlib list))
             (equal? (manifest-field legacy-list 'target)
                     '(stdlib list))
             (equal? (manifest-field legacy-case-lambda 'target)
                     '(scheme case-lambda))))")
    "#t")))

(ert-deftest consent-library-test-srfi-97-aliases-cover-supported-subset ()
  "Require SRFI 97 aliases for supported SRFIs in its fixed library set."
  (let ((checked 0))
    (dolist (spec consent-library-test--srfi-97-library-references)
      (let* ((number (car spec))
             (primary-key (format "(srfi %d)" number))
             (primary-entry
              (consent--library-collection-manifest-entry primary-key)))
        (when primary-entry
          (cl-incf checked)
          (let ((target (or (plist-get primary-entry :target) primary-key)))
            (dolist (alias-key (cdr spec))
              (let ((alias-entry
                     (consent--library-collection-manifest-entry alias-key)))
                (should alias-entry)
                (should (eq (plist-get alias-entry :kind) 'library-alias))
                (should (equal (plist-get alias-entry :target) target))))))))
    (should (> checked 0))))

(ert-deftest consent-library-test-vendored-srfi-records-cover-intake-contract
  ()
  "Expose SRFI bundle intake metadata as Scheme-readable records."
  (let ((vendored (consent-library-test--vendored-srfi-record 1))
        (testing (consent-library-test--vendored-srfi-record 64))
        (random-bits (consent-library-test--vendored-srfi-record 27))
        (random-data (consent-library-test--vendored-srfi-record 194))
        (property-testing (consent-library-test--vendored-srfi-record 252))
        (lightweight-testing (consent-library-test--vendored-srfi-record 78))
        (cond-expand (consent-library-test--vendored-srfi-record 0))
        (shim (consent-library-test--vendored-srfi-record 16))
        (libraries (consent-library-test--vendored-srfi-record 97))
        (reference (consent-library-test--vendored-srfi-record 261))
        (missing (consent-library-test--vendored-srfi-record 99999)))
    (should (eq (car vendored) (consent--syntax-symbol "vendored-srfi")))
    (should (equal (consent-library-test--record-field-external
                    vendored 'number)
                   "1"))
    (should (equal (consent-library-test--record-field-external
                    vendored 'name)
                   "list"))
    (should (equal (consent-library-test--record-field-external
                    vendored 'library)
                   "(stdlib list)"))
    (should (equal (consent-library-test--record-field-external
                    vendored 'classification)
                   "vendored-library"))
    (should (equal (consent-library-test--record-field-external
                    vendored 'status)
                   "vendored-adapted-implementation"))
    (should (equal (consent-library-test--record-field
                    vendored 'source-url)
                   (concat "https://github.com/"
                           "scheme-requests-for-implementation/srfi-1")))
    (should (equal (consent-library-test--record-field
                    vendored 'license)
                   "MIT"))
    (should (equal (consent-library-test--record-field
                    vendored 'local-license)
                   "MIT"))
    (should (member "(srfi 1)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'import-names))))
    (should (member "(srfi srfi-1)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'import-names))))
    (should (member "(srfi :1 lists)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'import-names))))
    (should (member "(scheme list)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'import-names))))
    (should (member "(stdlib list)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'import-names))))
    (should (member "(library (scheme base))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'dependencies))))
    (should-not (equal (consent-library-test--record-field-external
                        vendored 'local-patches)
                       "()"))
    (should (member "portable-host-suite"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             vendored 'tests))))

    (should (equal (consent-library-test--record-field-external
                    testing 'number)
                   "64"))
    (should (equal (consent-library-test--record-field-external
                    testing 'name)
                   "testing"))
    (should (equal (consent-library-test--record-field-external
                    testing 'library)
                   "(stdlib testing)"))
    (should (equal (consent-library-test--record-field-external
                    testing 'classification)
                   "vendored-library"))
    (should (equal (consent-library-test--record-field
                    testing 'source-url)
                   (concat "https://github.com/"
                           "scheme-requests-for-implementation/srfi-64")))
    (should (member "(srfi 64)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'import-names))))
    (should (member "(srfi srfi-64)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'import-names))))
    (should (member "(srfi :64)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'import-names))))
    (should (member "(srfi :64 testing)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'import-names))))
    (should (member "(stdlib testing)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'import-names))))
    (should (member "(library (scheme eval))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'dependencies))))
    (should (member "adapted-upstream-tests"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             testing 'tests))))

    (should (equal (consent-library-test--record-field-external
                    lightweight-testing 'number)
                   "78"))
    (should (equal (consent-library-test--record-field-external
                    lightweight-testing 'name)
                   "lightweight-testing"))
    (should (equal (consent-library-test--record-field-external
                    lightweight-testing 'library)
                   "(stdlib lightweight-testing)"))
    (should (equal (consent-library-test--record-field-external
                    lightweight-testing 'classification)
                   "vendored-library"))
    (should (equal (consent-library-test--record-field-external
                    lightweight-testing 'status)
                   "vendored-adapted-implementation"))
    (should (equal (consent-library-test--record-field
                    lightweight-testing 'source-url)
                   "https://srfi.schemers.org/srfi-78/"))
    (should (equal (consent-library-test--record-field
                    lightweight-testing 'license)
                   "MIT"))
    (should (member "(srfi 78)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'import-names))))
    (should (member "(srfi srfi-78)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'import-names))))
    (should (member "(srfi :78)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'import-names))))
    (should (member "(srfi :78 lightweight-testing)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'import-names))))
    (should (member "(stdlib lightweight-testing)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'import-names))))
    (should (member "(library (stdlib eager-comprehensions))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'dependencies))))
    (should (member "adapted-upstream-examples"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'tests))))
    (should (member "portable-host-suite"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             lightweight-testing 'tests))))

    (should (equal (consent-library-test--record-field-external
                    random-bits 'number)
                   "27"))
    (should (equal (consent-library-test--record-field-external
                    random-bits 'name)
                   "random-bits"))
    (should (equal (consent-library-test--record-field-external
                    random-bits 'library)
                   "(stdlib random-bits)"))
    (should (equal (consent-library-test--record-field-external
                    random-bits 'classification)
                   "vendored-library"))
    (should (equal (consent-library-test--record-field-external
                    random-bits 'status)
                   "vendored-adapted-implementation"))
    (should (equal (consent-library-test--record-field
                    random-bits 'source-url)
                   (concat "https://github.com/"
                           "scheme-requests-for-implementation/srfi-27")))
    (should (equal (consent-library-test--record-field
                    random-bits 'license)
                   "MIT"))
    (should (member "(srfi 27)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'import-names))))
    (should (member "(srfi srfi-27)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'import-names))))
    (should (member "(srfi :27)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'import-names))))
    (should (member "(srfi :27 random-bits)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'import-names))))
    (should (member "(stdlib random-bits)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'import-names))))
    (should (member "(library (scheme time))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'dependencies))))
    (should (member "clock-grant-randomization"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'tests))))
    (should (member "portable-host-suite"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'tests))))
    (should (member "upstream-confidence-tests"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-bits 'tests))))

    (should (equal (consent-library-test--record-field-external
                    random-data 'number)
                   "194"))
    (should (equal (consent-library-test--record-field-external
                    random-data 'name)
                   "random-data-generators"))
    (should (equal (consent-library-test--record-field-external
                    random-data 'library)
                   "(stdlib random-data-generators)"))
    (should (equal (consent-library-test--record-field-external
                    random-data 'classification)
                   "vendored-library"))
    (should (equal (consent-library-test--record-field-external
                    random-data 'status)
                   "vendored-adapted-implementation"))
    (should (equal (consent-library-test--record-field
                    random-data 'source-url)
                   (concat "https://github.com/"
                           "scheme-requests-for-implementation/srfi-194")))
    (should (equal (consent-library-test--record-field
                    random-data 'license)
                   "MIT"))
    (should (member "(srfi 194)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'import-names))))
    (should (member "(srfi srfi-194)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'import-names))))
    (should (member "(stdlib random-data-generators)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'import-names))))
    (should (member "(library (stdlib random-bits))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'dependencies))))
    (should (member "(library (stdlib generator))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'dependencies))))
    (should (member "adapted-upstream-tests"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'tests))))
    (should (member "upstream-fixtures"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'tests))))
    (should (member "adapted-upstream-statistical-tests"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'tests))))
    (should (member "portable-host-suite"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             random-data 'tests))))

    (should (equal (consent-library-test--record-field-external
                    property-testing 'number)
                   "252"))
    (should (equal (consent-library-test--record-field-external
                    property-testing 'name)
                   "property-testing"))
    (should (equal (consent-library-test--record-field-external
                    property-testing 'library)
                   "(stdlib property-testing)"))
    (should (equal (consent-library-test--record-field-external
                    property-testing 'classification)
                   "vendored-library"))
    (should (equal (consent-library-test--record-field-external
                    property-testing 'status)
                   "vendored-adapted-implementation"))
    (should (equal (consent-library-test--record-field
                    property-testing 'source-url)
                   (concat "https://github.com/"
                           "scheme-requests-for-implementation/srfi-252")))
    (should (equal (consent-library-test--record-field
                    property-testing 'license)
                   "MIT"))
    (should (member "(srfi 252)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'import-names))))
    (should (member "(srfi srfi-252)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'import-names))))
    (should (member "(stdlib property-testing)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'import-names))))
    (should (member "(library (stdlib testing))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'dependencies))))
    (should (member "(library (stdlib random-data-generators))"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'dependencies))))
    (should (member "adapted-upstream-tests"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'tests))))
    (should (member "compiled-host-smoke"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             property-testing 'tests))))

    (should (equal (consent-library-test--record-field-external
                    cond-expand 'number)
                   "0"))
    (should (equal (consent-library-test--record-field-external
                    cond-expand 'classification)
                   "shim"))
    (should (equal (consent-library-test--record-field-external
                    cond-expand 'library)
                   "(srfi 0)"))
    (should (equal (consent-library-test--record-field-external
                    cond-expand 'target)
                   "(scheme base)"))
    (should (equal (consent-library-test--record-field-external
                    cond-expand 'status)
                   "built-in-shim"))
    (should (member "(srfi 0)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             cond-expand 'import-names))))
    (should (member "(srfi srfi-0)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             cond-expand 'import-names))))

    (should (equal (consent-library-test--record-field-external
                    shim 'number)
                   "16"))
    (should (equal (consent-library-test--record-field-external
                    shim 'classification)
                   "shim"))
    (should (equal (consent-library-test--record-field-external
                    shim 'library)
                   "(srfi 16)"))
    (should (equal (consent-library-test--record-field-external
                    shim 'target)
                   "(scheme case-lambda)"))
    (should (equal (consent-library-test--record-field-external
                    shim 'status)
                   "built-in-shim"))
    (should (member "(srfi :16 case-lambda)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             shim 'import-names))))
    (should (member "(srfi :16)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             shim 'import-names))))

    (should (equal (consent-library-test--record-field-external
                    libraries 'number)
                   "97"))
    (should (equal (consent-library-test--record-field-external
                    libraries 'classification)
                   "shim"))
    (should (equal (consent-library-test--record-field-external
                    libraries 'library)
                   "(srfi 97)"))
    (should (equal (consent-library-test--record-field-external
                    libraries 'target)
                   "(stdlib srfi-libraries)"))
    (should (member "(srfi 97)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             libraries 'import-names))))
    (should (member "(srfi srfi-97)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             libraries 'import-names))))
    (should (member "(srfi :97 srfi-libraries)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             libraries 'import-names))))
    (should (member "(srfi :97)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             libraries 'import-names))))

    (should (equal (consent-library-test--record-field-external
                    reference 'number)
                   "261"))
    (should (equal (consent-library-test--record-field-external
                    reference 'classification)
                   "shim"))
    (should (equal (consent-library-test--record-field-external
                    reference 'library)
                   "(srfi 261)"))
    (should (equal (consent-library-test--record-field-external
                    reference 'target)
                   "(stdlib srfi-reference)"))
    (should (equal (consent-library-test--record-field-external
                    reference 'status)
                   "built-in-shim"))
    (should (member "(srfi 261)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             reference 'import-names))))
    (should (member "(srfi srfi-261)"
                    (mapcar #'consent-datum->external
                            (consent-library-test--record-field
                             reference 'import-names))))

    (should (equal (consent-library-test--record-field-external
                    missing 'number)
                   "99999"))
    (should (equal (consent-library-test--record-field-external
                    missing 'status)
                   "missing"))
    (should (equal (consent-library-test--record-field-external
                    missing 'reason)
                   "missing-srfi"))))

(ert-deftest consent-library-test-dependency-solve-reports-missing-dependency
  ()
  "Report an unsatisfied dependency instead of returning a false solution."
  (unwind-protect
      (progn
        (consent--library-catalog-add-manifest
         'dependency-failure-fixture
         (consent-read
          "(library-catalog
             (manifest-entry
              (schema-version 1)
              (kind library)
              (name (project needs-missing))
              (owner project)
              (provider repo-source)
              (visibility public)
              (layer package)
              (category project)
              (source-kind source-library)
              (source (path \"project/needs-missing.sld\"))
              (api-version (compat 0))
              (source-version unknown)
              (realization portable-source)
              (exports (run))
              (dependencies ((library (scheme base))
                             (library (project absent))))
              (provenance ((origin test-fixture)))
              (status available)
              (canonical #t)))"))
        (let ((record
               (consent--library-solve-dependencies-record
                (consent-read "(project needs-missing)"))))
          (should (equal (consent-library-test--record-field-external
                          record 'status)
                         "unsatisfied-dependency"))
          (should (equal (consent-library-test--record-field-external
                          record 'reason)
                         "missing-dependency"))
          (should (member "(project absent)"
                          (mapcar #'consent-datum->external
                                  (consent-library-test--record-field
                                   record 'missing-dependencies))))))
    (consent--library-catalog-remove-manifest 'dependency-failure-fixture)))

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
