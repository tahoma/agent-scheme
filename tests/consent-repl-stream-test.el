;;; consent-repl-stream-test.el --- Incremental stdin REPL parity tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Coverage for the Emacs incremental, line-oriented Consent Scheme REPL entry
;; (`consent-repl-stream'), the Emacs parity twin of the portable terminal REPL
;; shell.  These tests exercise the same cross-host REPL interaction contract
;; (docs/repl-interaction-contract.md) scenarios the portable shell test asserts
;; (tests/scheme/consent-repl-test.scm): the emitted record vocabulary, durable
;; session evaluation, recoverable reader/evaluator conditions, EOF/exit close
;; status, policy-gated host-effect denial, and program-output/record stream
;; separation.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-repl-stream)
(require 'consent-result)

;;;; Record helpers (mirror the portable shell test's field/kind accessors)

(defun consent-repl-stream-test--field (datum name)
  "Return the single value of field NAME (a string) in record DATUM, or nil."
  (let ((entry (seq-find
                (lambda (candidate)
                  (and (consp candidate)
                       (consent-symbol-p (car candidate))
                       (equal (consent-symbol-name (car candidate)) name)))
                (cdr-safe datum))))
    (and entry (cadr entry))))

(defun consent-repl-stream-test--kind-p (record tag)
  "Return non-nil when RECORD is a contract record whose kind is TAG."
  (and (consp record)
       (consent-symbol-p (car record))
       (equal (consent-symbol-name (car record)) tag)))

(defun consent-repl-stream-test--of (records tag)
  "Return the RECORDS whose kind is TAG, in order."
  (seq-filter (lambda (record)
                (consent-repl-stream-test--kind-p record tag))
              records))

(defun consent-repl-stream-test--count (records tag)
  "Return the number of RECORDS whose kind is TAG."
  (length (consent-repl-stream-test--of records tag)))

(defun consent-repl-stream-test--sym (value)
  "Return the symbol name of a Scheme symbol datum VALUE, or nil."
  (and (consent-symbol-p value) (consent-symbol-name value)))

(defun consent-repl-stream-test--true-p (value)
  "Return non-nil when VALUE is the Scheme true boolean datum."
  (eq value consent-true))

(defun consent-repl-stream-test--false-p (value)
  "Return non-nil when VALUE is the Scheme false boolean datum."
  (eq value consent-false))

(defun consent-repl-stream-test--int (value)
  "Return host integer for a Scheme integer number datum VALUE."
  (consent-number-value value))

(defun consent-repl-stream-test--drive (input &optional options)
  "Drive INPUT through the incremental REPL under session `project-main'.
OPTIONS are evaluator options.  Return the ordered contract records."
  (consent-repl-stream-records-from-string input "project-main" options))

;;;; Simple expression evaluation through the runtime writer/result path

(ert-deftest consent-repl-stream-simple-evaluation ()
  "A simple expression yields a wrapped `evaluation-result' and a clean EOF close."
  (let* ((records (consent-repl-stream-test--drive "(+ 1 2)\n"))
         (result (car (consent-repl-stream-test--of records "repl-result"))))
    (should (equal (consent-repl-stream-test--field result "display") "3"))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field result "submission"))
                   "sub-1"))
    (let ((evaluation (consent-repl-stream-test--field result "evaluation-result")))
      (should (consent-repl-stream-test--kind-p evaluation "evaluation-result"))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field evaluation "status"))
                     "ok")))
    (let ((prompt (car (consent-repl-stream-test--of records "repl-prompt"))))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field prompt "state"))
                     "ready"))
      (should (consent-repl-stream-test--false-p
               (consent-repl-stream-test--field prompt "pending")))
      (should (= (consent-repl-stream-test--int
                  (consent-repl-stream-test--field prompt "ordinal"))
                 1)))
    (should (= (consent-repl-stream-test--count records "repl-exit") 1))
    (let ((exit (car (consent-repl-stream-test--of records "repl-exit"))))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field exit "reason"))
                     "eof"))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field exit "status"))
                     "closed-ok"))
      (should (= (consent-repl-stream-test--int
                  (consent-repl-stream-test--field exit "count"))
                 1)))))

;;;; Definitions, imports, and macros persist across submissions

(ert-deftest consent-repl-stream-persistent-session ()
  "Definitions, imports, and macros persist across separately submitted forms."
  (let* ((records
          (consent-repl-stream-test--drive
           (concat
            "(import (scheme base))\n"
            "(define base 20)\n"
            "(define-syntax inc (syntax-rules () ((_ v) (+ v 1))))\n"
            "(inc base)\n")))
         (results (consent-repl-stream-test--of records "repl-result")))
    (should (= (length results) 4))
    (should (equal (consent-repl-stream-test--field (nth 3 results) "display")
                   "21"))
    (should (= (consent-repl-stream-test--count records "repl-condition") 0))))

;;;; Session-gated interaction-environment resolves inside the session

(ert-deftest consent-repl-stream-interaction-environment ()
  "The policy-gated interaction-environment resolves inside the REPL session."
  (let* ((records
          (consent-repl-stream-test--drive
           (concat
            "(import (scheme base) (scheme eval) (scheme repl))\n"
            "(eval (quote (define made 5)) (interaction-environment))\n"
            "made\n")))
         (results (consent-repl-stream-test--of records "repl-result")))
    (should (equal (consent-repl-stream-test--field (nth 2 results) "display")
                   "5"))
    (should (= (consent-repl-stream-test--count records "repl-condition") 0))))

;;;; A recoverable evaluator condition keeps the session open

(ert-deftest consent-repl-stream-recoverable-evaluator-condition ()
  "A recoverable evaluator condition is reported without ending the session."
  (let* ((records (consent-repl-stream-test--drive "undefined-name\n(+ 4 5)\n"))
         (condition (car (consent-repl-stream-test--of records "repl-condition"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "phase"))
                   "eval"))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field condition "recoverable")))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "submission"))
                   "sub-1"))
    (let ((result (car (consent-repl-stream-test--of records "repl-result"))))
      (should (equal (consent-repl-stream-test--field result "display") "9")))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field
                     (car (consent-repl-stream-test--of records "repl-exit"))
                     "status"))
                   "closed-ok"))))

;;;; A recoverable reader condition keeps the session open

(ert-deftest consent-repl-stream-recoverable-reader-condition ()
  "A malformed datum is reported as a recoverable reader condition; eval resumes."
  (let* ((records (consent-repl-stream-test--drive ")\n(+ 6 7)\n"))
         (condition (car (consent-repl-stream-test--of records "repl-condition"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "phase"))
                   "read"))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field condition "recoverable")))
    (let ((result (car (consent-repl-stream-test--of records "repl-result"))))
      (should (equal (consent-repl-stream-test--field result "display") "13")))))

;;;; An incomplete form is continued, not reported as a hard error

(ert-deftest consent-repl-stream-incomplete-form-continues ()
  "An incomplete prefix re-prompts as a continuation on the same ordinal."
  (let* ((records (consent-repl-stream-test--drive "(+ 1\n2)\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt"))
         (submission (car (consent-repl-stream-test--of records "repl-submission"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field (nth 1 prompts) "state"))
                   "continuation"))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field (nth 1 prompts) "pending")))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 1 prompts) "ordinal"))
               1))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field submission "complete")))
    (should (equal (consent-repl-stream-test--field submission "source")
                   "(+ 1\n2)"))
    (should (equal (consent-repl-stream-test--field
                    (car (consent-repl-stream-test--of records "repl-result"))
                    "display")
                   "3"))))

;;;; EOF mid-form closes with the documented error status

(ert-deftest consent-repl-stream-eof-mid-form ()
  "Input ending while a partial form is buffered closes with `closed-error'."
  (let* ((records (consent-repl-stream-test--drive "(+ 1\n"))
         (submission (car (consent-repl-stream-test--of records "repl-submission")))
         (condition (car (consent-repl-stream-test--of records "repl-condition")))
         (exit (car (consent-repl-stream-test--of records "repl-exit"))))
    (should (consent-repl-stream-test--false-p
             (consent-repl-stream-test--field submission "complete")))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field submission "eof")))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "phase"))
                   "read"))
    (should (consent-repl-stream-test--false-p
             (consent-repl-stream-test--field condition "recoverable")))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field exit "reason"))
                   "eof"))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field exit "status"))
                   "closed-error"))))

;;;; Explicit exit closes with the explicit reason and clean status

(ert-deftest consent-repl-stream-explicit-exit ()
  "An explicit exit form closes once with reason `explicit' and `closed-ok'."
  (let* ((records (consent-repl-stream-test--drive "(+ 1 2)\n(exit)\n"))
         (exit (car (consent-repl-stream-test--of records "repl-exit"))))
    (should (= (consent-repl-stream-test--count records "repl-exit") 1))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field exit "reason"))
                   "explicit"))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field exit "status"))
                   "closed-ok"))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field exit "count"))
               2))))

(ert-deftest consent-repl-stream-explicit-exit-nonzero ()
  "An explicit exit carrying a nonzero object renders `closed-error' with detail."
  (let* ((records (consent-repl-stream-test--drive "(exit 7)\n"))
         (exit (car (consent-repl-stream-test--of records "repl-exit"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field exit "reason"))
                   "explicit"))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field exit "status"))
                   "closed-error"))
    (should (equal (consent-repl-stream-test--field exit "detail") "7"))))

;;;; Default policy denies an ungranted host effect, failing closed

(ert-deftest consent-repl-stream-policy-denial-fails-closed ()
  "An ungranted host effect is denied with a Scheme-readable condition record."
  (let* ((records
          (consent-repl-stream-test--drive
           (concat "(begin (import (scheme file)) "
                   "(open-output-file \"/tmp/consent-repl-stream-denied\"))\n")))
         (condition (car (consent-repl-stream-test--of records "repl-condition"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "phase"))
                   "eval"))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field condition "recoverable")))
    (let ((datum (consent-repl-stream-test--field condition "condition")))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field datum "type"))
                     "policy-denial")))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field
                     (car (consent-repl-stream-test--of records "repl-exit"))
                     "status"))
                   "closed-ok"))))

(ert-deftest consent-repl-stream-interaction-environment-denied ()
  "A session-policy denial of interaction-environment fails closed."
  (let* ((records
          (consent-repl-stream-test--drive
           (concat "(import (scheme base) (scheme repl))\n"
                   "(interaction-environment)\n")
           '(:policy-actions ((standard-host-effect . deny)))))
         (condition (car (consent-repl-stream-test--of records "repl-condition"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "phase"))
                   "eval"))
    (let ((datum (consent-repl-stream-test--field condition "condition")))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field datum "type"))
                     "policy-denial")))))

;;;; Program output is separated from the interaction record stream

(ert-deftest consent-repl-stream-separates-program-output ()
  "Program output reaches the output stream; records never carry it."
  (let ((records nil)
        (output nil)
        (lines (list "(import (scheme base) (scheme write))\n"
                     "(display \"emitted\")\n"
                     "(+ 1 2)\n"
                     "(exit)\n")))
    (let ((exit-code
           (consent-repl-stream-run
            (lambda ()
              (if (null lines)
                  consent-repl-stream--eof
                (pop lines)))
            (lambda (record) (push record records))
            (lambda (text) (push text output))
            "project-main")))
      (setq records (nreverse records))
      (setq output (nreverse output))
      (should (= exit-code 0))
      (should (equal (apply #'concat output) "emitted"))
      (should (= (consent-repl-stream-test--count records "repl-result") 3))
      (should (> (consent-repl-stream-test--count records "repl-exit") 0))
      ;; The program output is not duplicated into any result rendering; it
      ;; reached the program-output stream only.  (A `repl-submission' record
      ;; legitimately echoes the form's own source text, so the separation
      ;; claim is asserted against the result displays, not every record.)
      (should-not
       (seq-some
        (lambda (result)
          (let ((display (consent-repl-stream-test--field result "display")))
            (and (stringp display) (string-match-p "emitted" display))))
        (consent-repl-stream-test--of records "repl-result"))))))

;;;; The interactive command renders records into its transcript buffer

(ert-deftest consent-repl-stream-interactive-command-renders-records ()
  "`consent-repl-stream' returns records and renders them into its buffer."
  (when (get-buffer consent-repl-stream-buffer-name)
    (kill-buffer consent-repl-stream-buffer-name))
  (let ((records (consent-repl-stream "(+ 1 2)\n")))
    (should (= (consent-repl-stream-test--count records "repl-result") 1))
    (with-current-buffer consent-repl-stream-buffer-name
      (should (string-match-p "repl-result" (buffer-string)))
      (should (string-match-p "repl-exit" (buffer-string)))))
  (kill-buffer consent-repl-stream-buffer-name))

(provide 'consent-repl-stream-test)

;;; consent-repl-stream-test.el ends here
