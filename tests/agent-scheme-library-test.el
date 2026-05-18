;;; agent-scheme-library-test.el --- R7RS library/import tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for R7RS `define-library' forms, program-level imports,
;; import-set modifiers, explicit library environments, and exported macros.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'agent-scheme-eval)

(defun agent-scheme-library-test--external (source &optional environment)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source environment)))

(defconst agent-scheme-library-test--root
  (expand-file-name
   ".."
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Repository root for library fixture tests.")

(defconst agent-scheme-library-test--include-options
  (list :include-directory agent-scheme-library-test--root
        :include-paths
        (list (expand-file-name "fixtures/r7rs"
                                agent-scheme-library-test--root))
        :file-paths
        (list (expand-file-name "fixtures/r7rs"
                                agent-scheme-library-test--root)))
  "Policy options that allow R7RS fixture includes.")

(defun agent-scheme-library-test--external/options (source options)
  "Evaluate SOURCE with OPTIONS and return its stable external value."
  (agent-scheme-value->external
   (agent-scheme-eval-source source nil options)))

(defun agent-scheme-library-test--standard-source-spec (name specs)
  "Return the source library spec named NAME from SPECS."
  (cl-find name specs
           :key (lambda (spec) (plist-get spec :name))
           :test #'equal))

(ert-deftest agent-scheme-library-test-imports-scheme-base-into-empty-environment ()
  "Import `(scheme base)' into an otherwise empty program environment."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base))
      (+ 1 2)"
     (agent-scheme-make-empty-environment))
    "3")))

(ert-deftest agent-scheme-library-test-define-library-import-export ()
  "Define a library and import its exported value into a program."
  (should
   (equal
    (agent-scheme-library-test--external
     "(define-library (agent-scheme fixture math)
        (export answer)
        (import (scheme base))
        (begin
          (define answer 42)))
      (import (agent-scheme fixture math))
      answer")
    "42")))

(ert-deftest agent-scheme-library-test-import-set-modifiers ()
  "Apply only, except, prefix, and rename import modifiers."
  (should
   (equal
    (agent-scheme-library-test--external
     "(define-library (agent-scheme fixture modifiers)
        (export add sub hidden)
        (import (scheme base))
        (begin
          (define (add x y) (+ x y))
          (define (sub x y) (- x y))
          (define hidden 99)))
      (import (only (agent-scheme fixture modifiers) add)
              (except (prefix (agent-scheme fixture modifiers) lib-) lib-hidden)
              (rename (agent-scheme fixture modifiers) (sub minus)))
      (list (add 1 2)
            (lib-add 3 4)
            (lib-sub 10 6)
            (minus 8 5))")
    "(3 7 4 3)")))

(ert-deftest agent-scheme-library-test-export-rename ()
  "Export an internal binding under a different external name."
  (should
   (equal
    (agent-scheme-library-test--external
     "(define-library (agent-scheme fixture export-rename)
        (export (rename internal external))
        (import (scheme base))
        (begin
          (define internal 42)))
      (import (agent-scheme fixture export-rename))
      external")
    "42")))

(ert-deftest agent-scheme-library-test-emacs-capability-imports-are-empty ()
  "Recognize early Emacs capability libraries without adding bindings."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (emacs buffer))
      'ok")
    "ok")))

(ert-deftest agent-scheme-library-test-conflicting-imports-signal-error ()
  "Reject importing the same local name from different bindings."
  (should-error
   (agent-scheme-eval-source
    "(define-library (agent-scheme fixture left)
       (export value)
       (import (scheme base))
       (begin (define value 'left)))
     (define-library (agent-scheme fixture right)
       (export value)
       (import (scheme base))
       (begin (define value 'right)))
     (import (agent-scheme fixture left)
             (agent-scheme fixture right))
     value")
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-exported-macros-keep-library-scope ()
  "Import an exported syntax-rules macro with definition-scope references."
  (should
   (equal
    (agent-scheme-library-test--external
     "(define-library (agent-scheme fixture syntax)
        (export choose)
        (import (scheme base))
        (begin
          (define default 'library)
          (define-syntax choose
            (syntax-rules ()
              ((choose) default)))))
      (import (scheme base)
              (agent-scheme fixture syntax))
      (let ((default 'program))
        (choose))")
    "library")))

(ert-deftest agent-scheme-library-test-cond-expand-library-declaration ()
  "Expand library-level cond-expand clauses into declarations."
  (should
   (equal
    (agent-scheme-library-test--external
     "(define-library (agent-scheme fixture conditional)
        (cond-expand
          ((library (scheme base))
           (export answer)
           (import (scheme base))
           (begin (define answer 42)))
          (else
           (export answer)
           (begin (define answer 'missing)))))
      (import (agent-scheme fixture conditional))
      answer")
    "42")))

(ert-deftest agent-scheme-library-test-include-declarations-are-policy-gated ()
  "Keep library declarations that read host files behind a policy gate."
  (should-error
   (agent-scheme-eval-source
    "(define-library (agent-scheme fixture include)
       (export answer)
       (import (scheme base))
       (include \"fixtures/r7rs/conformance-cases.scm\"))")
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-include-reads-policy-allowed-body ()
  "Read library body forms from policy-allowed include files."
  (should
   (equal
    (agent-scheme-library-test--external/options
     "(define-library (agent-scheme fixture include-body)
        (export answer)
        (import (scheme base))
        (include \"fixtures/r7rs/include-body.scm\"))
      (import (agent-scheme fixture include-body))
      answer"
     agent-scheme-library-test--include-options)
    "42")))

(ert-deftest agent-scheme-library-test-include-ci-folds-policy-allowed-body ()
  "Read include-ci files with fold-case enabled."
  (should
   (equal
    (agent-scheme-library-test--external/options
     "(define-library (agent-scheme fixture include-ci-body)
        (export mixedanswer)
        (import (scheme base))
        (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
      (import (agent-scheme fixture include-ci-body))
      mixedanswer"
     agent-scheme-library-test--include-options)
    "42")))

(ert-deftest agent-scheme-library-test-include-library-declarations-splice ()
  "Splice policy-allowed library declarations into the current library."
  (should
   (equal
    (agent-scheme-library-test--external/options
     "(define-library (agent-scheme fixture included-declarations)
        (include-library-declarations
         \"fixtures/r7rs/include-library-declarations.scm\"))
      (import (agent-scheme fixture included-declarations))
      answer"
     agent-scheme-library-test--include-options)
    "42")))

(ert-deftest agent-scheme-library-test-standard-source-libraries-are-file-backed ()
  "Discover source files and exports for portable standard libraries."
  (let ((specs (agent-scheme-standard-source-library-specs)))
    (dolist (case '(("(scheme case-lambda)" ("case-lambda"))
                   ("(scheme lazy)"
                    ("delay" "delay-force" "force" "make-promise"
                     "promise?"))))
      (let* ((name (car case))
             (expected-exports (cadr case))
             (spec (agent-scheme-library-test--standard-source-spec
                    name specs))
             (source-file (plist-get spec :source-file)))
        (should spec)
        (should (equal (plist-get spec :exports) expected-exports))
        (should (file-readable-p source-file))
        (with-temp-buffer
          (insert-file-contents source-file)
          (should
           (string-match-p
            (regexp-quote (format "(define-library %s" name))
            (buffer-string))))))))

(ert-deftest agent-scheme-library-test-standard-case-lambda-import ()
  "Import `(scheme case-lambda)' through the library registry."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme case-lambda))
      ((case-lambda
         ((x) x)
         ((x y) (+ x y)))
       1 2)")
    "3"))
  (should
   (equal
    (agent-scheme-library-test--external
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

(ert-deftest agent-scheme-library-test-standard-char-and-cxr-imports ()
  "Import `(scheme char)' and `(scheme cxr)' bindings."
  (should
   (equal
    (agent-scheme-library-test--external
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

(ert-deftest agent-scheme-library-test-standard-lazy-import-memoizes ()
  "Import `(scheme lazy)' promises with memoizing force."
  (should
   (equal
    (agent-scheme-library-test--external
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

(ert-deftest agent-scheme-library-test-standard-write-import-string-output ()
  "Import `(scheme write)' in-memory string output procedures."
  (should
   (equal
   (agent-scheme-library-test--external
     "(import (scheme base) (scheme write))
      (let ((out (open-output-string)))
        (display \"ok\" out)
        (get-output-string out))")
    "\"ok\"")))

(ert-deftest agent-scheme-library-test-standard-write-shared-and-record-output ()
  "Import `(scheme write)' shared, simple, and record writer procedures."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme write))
      (let ((x (list 'a)))
        (let ((out (open-output-string)))
          (write-shared (list x x) out)
          (get-output-string out)))")
    "\"(#0=(a) #0#)\""))
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme write))
      (let ((x (list 'a)))
        (let ((out (open-output-string)))
          (write (list x x) out)
          (get-output-string out)))")
    "\"((a) (a))\""))
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme write))
      (let ((out (open-output-string)))
        (write '#1=(a . #1#) out)
        (get-output-string out))")
    "\"#0=(a . #0#)\""))
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme write))
      (let ((out (open-output-string)))
        (write-simple '#(1 \"x\") out)
        (get-output-string out))")
    "\"#(1 \\\"x\\\")\""))
  (should
   (equal
    (agent-scheme-library-test--external
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

(ert-deftest agent-scheme-library-test-string-ports-read-and-write-round-trip ()
  "Use pure textual string ports with the Agent Scheme reader and writer."
  (should
   (equal
    (agent-scheme-library-test--external
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
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme read) (scheme write))
      (let ((out (open-output-string)))
        (write '(a \"b\" #u8(1 2)) out)
        (read (open-input-string (get-output-string out))))")
    "(a \"b\" #u8(1 2))")))

(ert-deftest agent-scheme-library-test-bytevector-ports-read-and-write ()
  "Use pure binary bytevector ports without host file access."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base))
      (let ((in (open-input-bytevector #u8(1 2 3)))
            (out (open-output-bytevector)))
        (write-u8 (read-u8 in) out)
        (write-bytevector (read-bytevector 4 in) out)
        (list (eof-object? (read-u8 in))
              (get-output-bytevector out)))")
    "(#t #u8(1 2 3))")))

(ert-deftest agent-scheme-library-test-standard-eval-import-evaluates-scheme ()
  "Evaluate Scheme datums in explicit immutable Scheme environments."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme base) (scheme eval))
      (eval '(* 7 3) (environment '(scheme base)))")
    "21"))
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme eval))
     (eval '(define foo 32) (environment '(scheme base)))")
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-standard-load-is-policy-gated ()
  "Load Scheme source only when host file policy allows the path."
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme load))
     (load \"fixtures/r7rs/include-body.scm\")")
   :type 'agent-scheme-eval-error)
  (should
   (equal
    (agent-scheme-library-test--external/options
     "(import (scheme base) (scheme load))
      (load \"fixtures/r7rs/include-body.scm\")
      answer"
     agent-scheme-library-test--include-options)
    "42")))

(ert-deftest agent-scheme-library-test-standard-file-import-is-policy-gated ()
  "Keep `(scheme file)' host file effects behind explicit path policy."
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme file))
     (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")
   :type 'agent-scheme-eval-error)
  (should
   (equal
    (agent-scheme-library-test--external/options
     "(import (scheme base) (scheme file))
      (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
     agent-scheme-library-test--include-options)
    "#t")))

(ert-deftest agent-scheme-library-test-standard-host-libraries-are-policy-gated ()
  "Import host-effecting standard libraries while denying effects by default."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme process-context) (scheme time) (scheme repl))
      'ok")
    "ok"))
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme process-context))
     (command-line)")
   :type 'agent-scheme-eval-error)
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme time))
     (current-second)")
   :type 'agent-scheme-eval-error)
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base) (scheme repl))
     (interaction-environment)")
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-standard-r5rs-import ()
  "Import the practical R5RS compatibility layer."
  (should
   (equal
    (agent-scheme-library-test--external
     "(import (scheme r5rs))
      (list (+ 1 2)
            (exact->inexact 3)
            (inexact->exact 3.0))")
    "(3 3.0 3)")))

(ert-deftest agent-scheme-library-test-imported-values-are-immutable ()
  "Reject definitions and assignments that target imported values."
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base))
     (set! + 1)"
    (agent-scheme-make-empty-environment))
   :type 'agent-scheme-eval-error)
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base))
     (define + 1)"
    (agent-scheme-make-empty-environment))
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-imported-syntax-is-immutable ()
  "Reject syntax definitions that target imported keywords."
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base))
     (define-syntax and
       (syntax-rules ()
         ((and) #t)))"
    (agent-scheme-make-empty-environment))
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-duplicate-export-names-signal-error ()
  "Reject duplicate external names in a library export set."
  (should-error
   (agent-scheme-eval-source
    "(define-library (agent-scheme fixture duplicate-export)
       (export value value)
       (import (scheme base))
       (begin (define value 1)))")
   :type 'agent-scheme-eval-error))

(ert-deftest agent-scheme-library-test-program-imports-precede-body ()
  "Reject program imports after definitions or expressions begin."
  (should-error
   (agent-scheme-eval-source
    "(import (scheme base))
     1
     (import (scheme cxr))
     'ok"
    (agent-scheme-make-empty-environment))
   :type 'agent-scheme-eval-error))

;;; agent-scheme-library-test.el ends here
