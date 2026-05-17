;;; agent-scheme-library-test.el --- R7RS library/import tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for R7RS `define-library' forms, program-level imports,
;; import-set modifiers, explicit library environments, and exported macros.

;;; Code:

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
                                agent-scheme-library-test--root)))
  "Policy options that allow R7RS fixture includes.")

(defun agent-scheme-library-test--external/options (source options)
  "Evaluate SOURCE with OPTIONS and return its stable external value."
  (agent-scheme-value->external
   (agent-scheme-eval-source source nil options)))

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

;;; agent-scheme-library-test.el ends here
