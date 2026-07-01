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

(defconst consent-library-test--root
  (expand-file-name
   ".."
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Repository root for library fixture tests.")

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
                     "scheme/standard-library/case-lambda.sld")
                   ("(scheme lazy)"
                    ("delay" "delay-force" "force" "make-promise"
                     "promise?")
                     "scheme/standard-library/lazy.sld")))
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
     "(import (scheme base) (consent json))
      (json-null? (json-read (open-input-string \"null\")))")
    "#t")))

(ert-deftest consent-library-test-json-read-subset-filters-exports ()
  "Import the read-side JSON facade without the write-side API."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (consent json read))
      (json-null? (json-read (open-input-string \"null\")))")
    "#t"))
  (should-error
   (consent-library-test--external
    "(import (scheme base)
             (only (consent json read) json-write))
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

(ert-deftest consent-library-test-srfi-manifest-documents-180 ()
  "Expose SRFI 180 support status through a Scheme-readable manifest."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi manifest))
      (let ((entry (srfi-manifest-ref '(srfi 180))))
        (list (cdr (assq 'status entry))
              (cdr (assq 'implementation-library entry))
              (cdr (assq 'upstream-license entry))
              (cdr (assq 'import-aliases entry))))")
    "(direct-portable-implementation (consent json) \"MIT\" ((srfi 180) (srfi srfi-180)))")))

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

(ert-deftest consent-library-test-srfi-128-comparator-behavior ()
  "Import `(scheme comparator)' and exercise representative SRFI 128 behavior."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (scheme comparator))
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

(ert-deftest consent-library-test-srfi-manifest-documents-128 ()
  "Expose SRFI 128 support status through a Scheme-readable manifest."
  (should
   (equal
    (consent-library-test--external
     "(import (scheme base) (srfi manifest))
      (let ((entry (srfi-manifest-ref '(scheme comparator)))
            (alias (srfi-manifest-ref '(srfi 128)))
            (portable-alias (srfi-manifest-ref '(srfi srfi-128))))
        (list (cdr (assq 'status entry))
              (cdr (assq 'implementation-library entry))
              (cdr (assq 'upstream-license entry))
              (cdr (assq 'local-license entry))
              (cdr (assq 'import-aliases entry))
              (cdr (assq 'dependencies entry))
              (cdr (assq 'target alias))
              (cdr (assq 'target portable-alias))))")
    "(vendored-adapted-implementation (scheme comparator) \"MIT\" \"MIT\" ((scheme comparator) (srfi 128) (srfi srfi-128)) ((scheme base) (scheme case-lambda) (scheme char) (scheme inexact) (scheme complex)) (scheme comparator) (scheme comparator))")))

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
