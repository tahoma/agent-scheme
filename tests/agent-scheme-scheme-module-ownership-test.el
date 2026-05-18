;;; agent-scheme-scheme-module-ownership-test.el --- Portable module ownership checks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Structural checks for the portable R7RS pass-boundary libraries.  These
;; tests catch facade regressions where a pass module merely re-exports the
;; monolithic evaluator instead of owning its definitions.

;;; Code:

(require 'ert)

(defun agent-scheme-scheme-module-ownership-test--read (path)
  "Return repository-relative PATH contents."
  (with-temp-buffer
    (insert-file-contents (expand-file-name path agent-scheme--test-root))
    (buffer-string)))

(defun agent-scheme-scheme-module-ownership-test--imports-eval-p (source)
  "Return non-nil when SOURCE imports the portable evaluator module."
  (string-match-p "(agent-scheme eval)" source))

(ert-deftest agent-scheme-scheme-module-ownership-test-runtime-result-own-definitions ()
  "Keep runtime values and result rendering out of the portable evaluator."
  (let ((runtime
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/runtime.sld"))
        (result
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/result.sld"))
        (eval
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/eval.sld")))
    (should-not
     (agent-scheme-scheme-module-ownership-test--imports-eval-p runtime))
    (should-not
     (agent-scheme-scheme-module-ownership-test--imports-eval-p result))
    (should
     (string-match-p "(define-record-type <eval-context>" runtime))
    (should-not
     (string-match-p "(define-record-type <eval-context>" eval))
    (should
     (string-match-p "(define (agent-scheme-value->external" result))
    (should-not
     (string-match-p "(define (agent-scheme-value->external" eval))))

(ert-deftest agent-scheme-scheme-module-ownership-test-base-owns-registry ()
  "Keep the portable base registry out of the evaluator module."
  (let ((base
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/base.sld"))
        (eval
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/eval.sld")))
    (should-not
     (agent-scheme-scheme-module-ownership-test--imports-eval-p base))
    (should
     (string-match-p "(define base-primitive-registry" base))
    (should-not
     (string-match-p "(define base-primitive-registry" eval))
    (should
     (string-match-p
      "(define (agent-scheme-install-base-backend!" base))))

(ert-deftest agent-scheme-scheme-module-ownership-test-library-owns-resolver ()
  "Keep the portable library resolver out of the evaluator module."
  (let ((library
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/library.sld"))
        (eval
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/eval.sld")))
    (should-not
     (agent-scheme-scheme-module-ownership-test--imports-eval-p library))
    (should
     (string-match-p "(define (resolve-library" library))
    (should-not
     (string-match-p "(define (resolve-library" eval))
    (should
     (string-match-p
      "(define (agent-scheme-install-library-backend!" library))))

(ert-deftest agent-scheme-scheme-module-ownership-test-macro-owns-expander ()
  "Keep the portable macro expander out of the evaluator module."
  (let ((macro
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/macro.sld"))
        (eval
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/eval.sld")))
    (should-not
     (agent-scheme-scheme-module-ownership-test--imports-eval-p macro))
    (should
     (string-match-p "(define (apply-syntax-transformer" macro))
    (should-not
     (string-match-p "(define (apply-syntax-transformer" eval))
    (should
     (string-match-p "(define (agent-scheme-expand-source" macro))))

(ert-deftest agent-scheme-scheme-module-ownership-test-interpreter-owns-backend ()
  "Keep the portable interpreter backend out of the evaluator facade."
  (let ((interpreter
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/interpreter.sld"))
        (eval
         (agent-scheme-scheme-module-ownership-test--read
          "scheme/agent-scheme/eval.sld")))
    (should-not
     (agent-scheme-scheme-module-ownership-test--imports-eval-p interpreter))
    (should
     (string-match-p "(define (trampoline" interpreter))
    (should-not
     (string-match-p "(define (trampoline" eval))
    (should
     (< (length (split-string eval "\n")) 80))))

;;; agent-scheme-scheme-module-ownership-test.el ends here
