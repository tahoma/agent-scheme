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

;;; agent-scheme-scheme-module-ownership-test.el ends here
