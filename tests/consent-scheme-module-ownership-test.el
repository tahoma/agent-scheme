;;; consent-scheme-module-ownership-test.el --- Portable module ownership checks  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Structural checks for the portable R7RS pass-boundary libraries.  These
;; tests catch facade regressions where a pass module merely re-exports the
;; monolithic evaluator instead of owning its definitions.

;;; Code:

(require 'ert)

(defun consent-scheme-module-ownership-test--read (path)
  "Return repository-relative PATH contents."
  (with-temp-buffer
    (insert-file-contents (expand-file-name path consent--test-root))
    (buffer-string)))

(defun consent-scheme-module-ownership-test--imports-eval-p (source)
  "Return non-nil when SOURCE imports the portable evaluator module."
  (string-match-p "(consent eval)" source))

(ert-deftest consent-scheme-module-ownership-test-runtime-result-own-definitions ()
  "Keep runtime values and result rendering out of the portable evaluator."
  (let ((runtime
         (consent-scheme-module-ownership-test--read
          "scheme/consent/runtime.sld"))
        (result
         (consent-scheme-module-ownership-test--read
          "scheme/consent/result.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p runtime))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p result))
    (should
     (string-match-p "(define-record-type <eval-context>" runtime))
    (should-not
     (string-match-p "(define-record-type <eval-context>" eval))
    (should
     (string-match-p "(define (consent-value->external" result))
    (should-not
     (string-match-p "(define (consent-value->external" eval))))

(ert-deftest consent-scheme-module-ownership-test-base-owns-registry ()
  "Keep the portable base registry out of the evaluator module."
  (let ((base
         (consent-scheme-module-ownership-test--read
          "scheme/consent/base.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p base))
    (should
     (string-match-p "(define base-primitive-registry" base))
    (should-not
     (string-match-p "(define base-primitive-registry" eval))
    (should
     (string-match-p
      "(define (consent-install-base-backend!" base))))

(ert-deftest consent-scheme-module-ownership-test-library-owns-resolver ()
  "Keep the portable library resolver out of the evaluator module."
  (let ((library
         (consent-scheme-module-ownership-test--read
          "scheme/consent/library.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p library))
    (should
     (string-match-p "(define (resolve-library" library))
    (should-not
     (string-match-p "(define (resolve-library" eval))
    (should
     (string-match-p
      "(define (consent-install-library-backend!" library))))

(ert-deftest consent-scheme-module-ownership-test-macro-owns-expander ()
  "Keep the portable macro expander out of the evaluator module."
  (let ((macro
         (consent-scheme-module-ownership-test--read
          "scheme/consent/macro.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p macro))
    (should
     (string-match-p "(define (apply-syntax-transformer" macro))
    (should-not
     (string-match-p "(define (apply-syntax-transformer" eval))
    (should
     (string-match-p "(define (consent-expand-source" macro))))

(ert-deftest consent-scheme-module-ownership-test-interpreter-owns-backend ()
  "Keep the portable interpreter backend out of the evaluator facade."
  (let ((interpreter
         (consent-scheme-module-ownership-test--read
          "scheme/consent/interpreter.sld"))
        (eval
         (consent-scheme-module-ownership-test--read
          "scheme/consent/eval.sld")))
    (should-not
     (consent-scheme-module-ownership-test--imports-eval-p interpreter))
    (should
     (string-match-p "(define (trampoline" interpreter))
    (should-not
     (string-match-p "(define (trampoline" eval))
    (should
     (< (length (split-string eval "\n")) 80))))

;;; consent-scheme-module-ownership-test.el ends here
