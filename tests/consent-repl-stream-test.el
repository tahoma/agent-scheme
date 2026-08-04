;;; consent-repl-stream-test.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Coverage for the Emacs incremental, line-oriented Consent Scheme REPL entry
;; (`consent-repl-stream'), the Emacs parity twin of the portable terminal REPL
;; shell.  These tests exercise the same cross-host REPL interaction contract
;; (docs/repl-interaction-contract.md) scenarios the portable shell test
;; asserts
;; (tests/scheme/consent-repl-test.scm): the emitted record vocabulary, durable
;; session evaluation, recoverable reader/evaluator conditions, EOF/exit close
;; status, policy-gated host-effect denial, and program-output/record stream
;; separation.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-eval)
(require 'consent-reader)
(require 'consent-repl-chrome)
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
  "A simple expression yields a wrapped `evaluation-result' and a clean EOF\
 close."
  (let* ((records (consent-repl-stream-test--drive "(+ 1 2)\n"))
         (result (car (consent-repl-stream-test--of records "repl-result"))))
    (should (equal (consent-repl-stream-test--field result "display") "3"))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field result "submission"))
                   "sub-1"))
    (let ((evaluation (consent-repl-stream-test--field result
      "evaluation-result")))
      (should (consent-repl-stream-test--kind-p evaluation
        "evaluation-result"))
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

(ert-deftest consent-repl-stream-reflection-tutorial-import-registry ()
  "Reflection tutorial imports persist in the live library registry."
  (let* ((records
          (consent-repl-stream-test--drive
           (concat
            "(import (scheme base) (agent reflect))\n"
            "(current-imports)\n"
            "(map (lambda (binding)\n"
            "       (list (reflection-field binding 'name)\n"
            "             (reflection-field binding 'kind)\n"
            "             (reflection-field binding 'library)))\n"
            "     (library-bindings '(agent reflect)))\n")))
         (results (consent-repl-stream-test--of records "repl-result")))
    (should (= (length results) 3))
    (let ((imports (consent-repl-stream-test--field (nth 1 results) "display"))
          (bindings (consent-repl-stream-test--field (nth 2 results)
            "display")))
      (should (string-match-p (regexp-quote "(agent reflect)") imports))
      (should (string-match-p (regexp-quote "(scheme base)") imports))
      (should (string-match-p
               (regexp-quote "(apropos value (agent reflect))")
               bindings)))
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
  (let* ((records (consent-repl-stream-test--drive
    "undefined-name\n(+ 4 5)\n"))
         (condition (car (consent-repl-stream-test--of records
           "repl-condition"))))
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

(ert-deftest consent-repl-stream-unbound-identifier-display-names-symbol ()
  "Unbound identifier conditions display the missing binding name."
  (let* ((records
          (consent-repl-stream-test--drive
           (concat
            "(define (uses-missing-helper value)\n"
            "  (missing-helper value))\n"
            "(uses-missing-helper '(a b))\n")))
         (condition (car (consent-repl-stream-test--of records
           "repl-condition")))
         (condition-datum (consent-repl-stream-test--field condition
           "condition")))
    (should (equal (consent-repl-stream-test--field condition "display")
                   "consent eval error: unbound identifier: missing-helper"))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition-datum "symbol"))
                   "missing-helper"))))

;;;; A recoverable reader condition keeps the session open

(ert-deftest consent-repl-stream-recoverable-reader-condition ()
  "A malformed datum is reported as a recoverable reader condition; eval\
 resumes."
  (let* ((records (consent-repl-stream-test--drive ")\n(+ 6 7)\n"))
         (condition (car (consent-repl-stream-test--of records
           "repl-condition"))))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field condition "phase"))
                   "read"))
    (should (consent-repl-stream-test--true-p
             (consent-repl-stream-test--field condition "recoverable")))
    (let ((result (car (consent-repl-stream-test--of records "repl-result"))))
      (should (equal (consent-repl-stream-test--field result "display")
        "13")))))

;;;; An incomplete form is continued, not reported as a hard error

(ert-deftest consent-repl-stream-incomplete-form-continues ()
  "An incomplete prefix re-prompts as a continuation on the same ordinal."
  (let* ((records (consent-repl-stream-test--drive "(+ 1\n2)\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt"))
         (submission (car (consent-repl-stream-test--of records
           "repl-submission"))))
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

;;;; Blank ready-prompt input redraws a same-ordinal ready prompt

(ert-deftest consent-repl-stream-blank-ready-prompt-reprompts ()
  "Blank ready-prompt input redraws a ready prompt without a submission."
  (let* ((records (consent-repl-stream-test--drive "\n(+ 1 2)\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt")))
    (should (= (length prompts) 3))
    (dolist (prompt prompts)
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field prompt "state"))
                     "ready")))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 0 prompts) "ordinal"))
               1))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 1 prompts) "ordinal"))
               1))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 2 prompts) "ordinal"))
               2))
    (should (= (consent-repl-stream-test--count records "repl-submission") 1))
    (should (equal
             (consent-repl-stream-test--field
              (car (consent-repl-stream-test--of records "repl-result"))
              "display")
             "3"))))

(ert-deftest consent-repl-stream-line-comment-ready-prompt-reprompts ()
  "Line-comment-only ready input redraws a ready prompt without a submission."
  (let* ((records (consent-repl-stream-test--drive "  ;; comment\n(+ 1 2)\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt"))
         (submissions
          (consent-repl-stream-test--of records "repl-submission")))
    (should (= (length prompts) 3))
    (dolist (prompt prompts)
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field prompt "state"))
                     "ready")))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 0 prompts) "ordinal"))
               1))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 1 prompts) "ordinal"))
               1))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 2 prompts) "ordinal"))
               2))
    (should (= (length submissions) 1))
    (should (equal (consent-repl-stream-test--field
                    (car submissions) "source")
                   "(+ 1 2)"))
    (should (equal
             (consent-repl-stream-test--field
              (car (consent-repl-stream-test--of records "repl-result"))
              "display")
             "3"))))

;;;; The continuation prompt carries the reader's pending-nesting indicator

(ert-deftest consent-repl-stream-continuation-carries-nesting ()
  "Carry nesting depth and the innermost pending construct kind on\
 continuation.
The depth narrows as constructs close (two open lists, then one), the kind
names the innermost pending construct, and a ready prompt omits both fields."
  (let* ((records (consent-repl-stream-test--drive "(+ (* 2\n3)\n4)\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt")))
    (should-not (consent-repl-stream-test--field (nth 0 prompts) "nesting"))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 1 prompts) "nesting"))
               2))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field (nth 1 prompts)
                                                     "pending-kind"))
                   "list"))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 2 prompts) "nesting"))
               1))))

(ert-deftest consent-repl-stream-continuation-pending-string-kind ()
  "Report an unterminated string as the innermost pending construct."
  (let* ((records (consent-repl-stream-test--drive
                   "(string-length \"a\nb\")\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt")))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 1 prompts) "nesting"))
               2))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field (nth 1 prompts)
                                                     "pending-kind"))
                   "string"))))

(ert-deftest consent-repl-stream-continuation-pending-datum-prefix ()
  "Continue a pending datum prefix with depth zero and the `datum' kind."
  (let* ((records (consent-repl-stream-test--drive "'\n1\n"))
         (prompts (consent-repl-stream-test--of records "repl-prompt")))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field (nth 1 prompts) "nesting"))
               0))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field (nth 1 prompts)
                                                     "pending-kind"))
                   "datum"))
    (should (equal (consent-repl-stream-test--field
                    (car (consent-repl-stream-test--of records "repl-result"))
                    "display")
                   "1"))))

;;;; The continuation prompt is emitted before the read it requests

(ert-deftest consent-repl-stream-continuation-prompt-precedes-read ()
  "The continuation gutter is emitted before the blocking read it requests.
A continuation prompt is a request for more input, so it must be emitted before
the read that supplies the continued line; on a live TTY a prompt emitted after
the read would land glued to the next result line.  The record-stream order
alone cannot see this -- a fully buffered string never blocks -- so instrument
the read/emit interleaving directly and assert exactly one chunk is read before
the prompt is emitted."
  (let* ((chunks (list "(+ 1\n" "2)\n"))
         (events '())
         (read-chunk
          (lambda ()
            (if (null chunks)
                consent-repl-stream--eof
              (let ((chunk (car chunks)))
                (setq chunks (cdr chunks))
                (push (list 'read chunk) events)
                chunk)))))
    (consent-repl-stream-run
     read-chunk
     (lambda (record)
       (when (and (consent-repl-stream-test--kind-p record "repl-prompt")
                  (equal (consent-repl-stream-test--sym
                          (consent-repl-stream-test--field record "state"))
                         "continuation"))
         (push 'continuation-prompt events)))
     (lambda (_output) nil)
     "repl-main")
    ;; The first chunk is read, then the gutter is emitted, then the continued
    ;; line is read: the prompt fronts the second line rather than trailing it.
    (should (equal (reverse events)
                   (list (list 'read "(+ 1\n")
                         'continuation-prompt
                         (list 'read "2)\n"))))))

;;;; EOF mid-form closes with the documented error status

(ert-deftest consent-repl-stream-eof-mid-form ()
  "Input ending while a partial form is buffered closes with `closed-error'."
  (let* ((records (consent-repl-stream-test--drive "(+ 1\n"))
         (submission (car (consent-repl-stream-test--of records
           "repl-submission")))
         (condition (car (consent-repl-stream-test--of records
           "repl-condition")))
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
  "An explicit exit carrying a nonzero object renders `closed-error' with\
 detail."
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
                   "(open-output-file\
 \"/tmp/consent-repl-stream-denied\"))\n")))
         (condition (car (consent-repl-stream-test--of records
           "repl-condition"))))
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
         (condition (car (consent-repl-stream-test--of records
           "repl-condition"))))
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

;;;; The interactive command renders records through the shared chrome

(ert-deftest consent-repl-stream-interactive-command-renders-comment-chrome ()
  "`consent-repl-stream' returns records and paints them through the default\
 chrome."
  (when (get-buffer consent-repl-stream-buffer-name)
    (kill-buffer consent-repl-stream-buffer-name))
  (let ((records (consent-repl-stream "(+ 1 2)\n")))
    (should (= (consent-repl-stream-test--count records "repl-result") 1))
    (with-current-buffer consent-repl-stream-buffer-name
      ;; The default `comment' chrome renders aligned line comments, not raw
      ;; tags.
      (should (string-match-p (regexp-quote ";;   => 3") (buffer-string)))
      (should (string-match-p (regexp-quote ";;   __ exit closed-ok")
                              (buffer-string)))
      (should-not (string-match-p "repl-result" (buffer-string)))
      ;; Faces realize the chrome roles in the buffer.
      (should (text-property-not-all
               (point-min) (point-max) 'face nil))))
  (kill-buffer consent-repl-stream-buffer-name))

(ert-deftest consent-repl-stream-interactive-command-datum-chrome ()
  "The `datum' chrome keeps the canonical raw record stream reachable in the\
 buffer."
  (when (get-buffer consent-repl-stream-buffer-name)
    (kill-buffer consent-repl-stream-buffer-name))
  (consent-repl-stream "(+ 1 2)\n" nil 'datum)
  (with-current-buffer consent-repl-stream-buffer-name
    (should (string-match-p "repl-result" (buffer-string)))
    (should (string-match-p "repl-exit" (buffer-string)))
    ;; The raw datum stream is never faced.
    (should-not (text-property-not-all (point-min) (point-max) 'face nil)))
  (kill-buffer consent-repl-stream-buffer-name))

;;;; The shared chrome model: same names and record-to-role mapping as portable

(defun consent-repl-stream-test--result-displays (records)
  "Return the ordered `display' strings of the `repl-result' RECORDS."
  (mapcar (lambda (result) (consent-repl-stream-test--field result "display"))
          (consent-repl-stream-test--of records "repl-result")))

(ert-deftest consent-repl-stream-chrome-registry ()
  "The registry exposes the same names and default as the portable renderer."
  (should (eq (consent-repl-chrome-default-name) 'comment))
  (should (functionp (consent-repl-chrome-lookup 'comment)))
  (should (functionp (consent-repl-chrome-lookup "classic")))
  (should-not (consent-repl-chrome-lookup 'no-such-chrome))
  (let ((names (consent-repl-chrome-names)))
    (dolist (name '(comment datum classic quiet silent))
      (should (memq name names)))))

(ert-deftest consent-repl-stream-chrome-datum-recovers-raw-stream ()
  "The `datum' chrome reproduces the raw record stream and is never faced."
  (let* ((input "(+ 1 2)\n(exit)\n")
         (records (consent-repl-stream-records-from-string input "repl-main"))
         (raw (mapconcat (lambda (record)
                           (concat (consent-result->external record) "\n"))
                         records ""))
         (plain (consent-repl-stream-rendered-from-string
                 input "repl-main" 'datum nil))
         (faced (consent-repl-stream-rendered-from-string
                 input "repl-main" 'datum t)))
    (should (equal plain raw))
    ;; The datum chrome is byte-identical with faces requested, and unfaced.
    (should (equal (substring-no-properties faced) raw))
    (should-not (text-property-not-all 0 (length faced) 'face nil faced))))

(ert-deftest consent-repl-stream-chrome-comment-replays-unedited ()
  "The `comment' chrome is valid, replayable Consent Scheme."
  (let* ((input "(+ 1 2)\n(define base 7)\n(* base 3)\n")
         (rendered (consent-repl-stream-rendered-from-string
                    input "repl-main" 'comment nil)))
    (should (string-match-p (regexp-quote "#| ") rendered))
    ;; Re-driving the rendered control stream reproduces the same results: the
    ;; comments are ignored and the echoed forms re-evaluate identically.
    (should (equal (consent-repl-stream-test--result-displays
                    (consent-repl-stream-records-from-string rendered
                      "repl-main"))
                   (consent-repl-stream-test--result-displays
                    (consent-repl-stream-records-from-string input
                      "repl-main"))))))

(ert-deftest consent-repl-stream-chrome-comment-prompt-shapes ()
  "The default session shows the ordinal alone; a named session grows a label.
The result is a `;;'-aligned line comment plus a `;;' separator, and the EOF
exit is a `;;   __ ' line, byte-identical to the portable renderer."
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ 1 2)\n" "repl-main" 'comment nil)
                 "#| 1 |# (+ 1 2)\n;;   => 3\n;;\n#| 2 |# ;;   __ exit\
 closed-ok\n"))
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ 1 2)\n" "project-main" 'comment nil)
                 (concat
                  "#| project-main:1 |# (+ 1 2)\n;;                => 3\n;;\n"
                  "#| project-main:2 |# ;;                __ exit\
 closed-ok\n"))))

(ert-deftest consent-repl-stream-chrome-comment-marker-alignment ()
  "Result/output markers track the ordinal width, matching the portable shell."
  (should (equal (consent-repl-stream-rendered-from-string
                  "1\n2\n3\n4\n5\n6\n7\n8\n9\n(+ 1 1)\n" "repl-main" 'comment
                    nil)
                 (concat
                  "#| 1 |# 1\n;;   => 1\n;;\n#| 2 |# 2\n;;   => 2\n;;\n"
                  "#| 3 |# 3\n;;   => 3\n;;\n#| 4 |# 4\n;;   => 4\n;;\n"
                  "#| 5 |# 5\n;;   => 5\n;;\n#| 6 |# 6\n;;   => 6\n;;\n"
                  "#| 7 |# 7\n;;   => 7\n;;\n#| 8 |# 8\n;;   => 8\n;;\n"
                  "#| 9 |# 9\n;;   => 9\n;;\n#| 10 |# (+ 1 1)\n;;    =>\
 2\n;;\n"
                  "#| 11 |# ;;    __ exit closed-ok\n"))))

(ert-deftest consent-repl-stream-chrome-comment-input-echoed-suppresses-echo ()
  "When the host already echoes input, the comment chrome drops its own echo.
This is the parity twin of the portable terminal shell's interactive-TTY
posture: the terminal's own cooked-mode echo is the single replayable copy, so\
 a
second chrome echo would replay each form twice.  Both Emacs entries leave the
flag nil today (piped batch stdin and buffer rendering never terminal-echo);\
 the
flag exists for model symmetry and is exercised here through the rendered\
 hook."
  (let* ((input "(+ 1 2)\n(define base 7)\n(set! base 9)\n(* base 3)\n")
         (echoed (consent-repl-stream-rendered-from-string
                  input "repl-main" 'comment nil nil t)))
    ;; The interactive render carries no bare submission echo, so re-driving
    ;; the
    ;; chrome output alone evaluates nothing: the single copy is the terminal
    ;; echo (the input), never a duplicate in the control channel.
    (should (equal (consent-repl-stream-test--result-displays
                    (consent-repl-stream-records-from-string echoed
                      "repl-main"))
                   nil))
    ;; Prompts and results still render as line comments; only the redundant
    ;; submission echo is dropped.
    (should (string-match-p (regexp-quote ";;   => ") echoed))
    ;; The bare submission echo lands in the prompt slot the terminal echo
    ;; fills.
    (should (equal (consent-repl-stream-rendered-from-string
                    "(+ 1 2)\n" "repl-main" 'comment nil nil t)
                   "#| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit\
 closed-ok\n"))))

(ert-deftest consent-repl-stream-chrome-blank-ready-prompt-reprompts ()
  "Human chromes redraw a same-ordinal ready prompt after blank input."
  ;; These helpers render only the control channel.  In a live TTY, the echoed
  ;; blank line and typed datum appear between the repeated ready prompts.
  (should (equal (consent-repl-stream-rendered-from-string
                  "\n(+ 1 2)\n" "repl-main" 'comment nil nil t)
                 "#| 1 |# #| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit\
 closed-ok\n"))
  (should (equal (consent-repl-stream-rendered-from-string
                  "\n(+ 1 2)\n" "repl-main" 'classic nil nil t)
                 "> > = 3\n\n> _ exit closed-ok\n"))
  (should (equal (consent-repl-stream-rendered-from-string
                  "  ;; comment\n(+ 1 2)\n" "repl-main" 'comment nil nil t)
                 "#| 1 |# #| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit\
 closed-ok\n"))
  (should (equal (consent-repl-stream-rendered-from-string
                  "  ;; comment\n(+ 1 2)\n" "repl-main" 'classic nil nil t)
                 "> > = 3\n\n> _ exit closed-ok\n")))

(ert-deftest consent-repl-stream-chrome-classic-quiet-silent ()
  "The `classic', `quiet', and `silent' chromes match the portable rendering.
`classic' echoes the whole form after `> ', marks the value `= ', and closes
with a `_ ' exit line; a `! ' marks a condition."
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ 1 2)\n" "repl-main" 'classic nil)
                 "> (+ 1 2)\n= 3\n\n> _ exit closed-ok\n"))
  ;; The condition is marked `! ', and its diagnostic text is now
  ;; byte-identical
  ;; to the portable twin for an error whose wording agrees (the Emacs runtime
  ;; renders the `consent eval error: ' prefix unquoted, matching portable), so
  ;; assert the whole line exactly across hosts.
  (should (equal (consent-repl-stream-rendered-from-string
                  "(/ 1 0)\n" "repl-main" 'classic nil)
                 (concat "> (/ 1 0)\n! consent eval error: / division by zero"
                         "\n\n> _ exit closed-ok\n")))
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ 1 2)\n" "repl-main" 'quiet nil)
                 "3\n"))
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ 1 2)\n" "repl-main" 'silent nil)
                 "")))

(ert-deftest consent-repl-stream-chrome-continuation-gutters ()
  "Continuation gutters are clean, width-matched, and carry no nesting count.
The classic gutter is `. ' (one per continuation read) and the comment gutter
is alignment dots as wide as the prompt body, matching the portable renderer."
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ (* 2\n3)\n4)\n" "repl-main" 'classic nil)
                 "> . . (+ (* 2\n3)\n4)\n= 10\n\n> _ exit closed-ok\n"))
  (should (equal (consent-repl-stream-rendered-from-string
                  "(+ 1\n2)\n" "repl-main" 'classic nil)
                 "> . (+ 1\n2)\n= 3\n\n> _ exit closed-ok\n"))
  (should (string-match-p (regexp-quote "#| . |# ")
                          (consent-repl-stream-rendered-from-string
                           "(+ (* 2\n3)\n4)\n" "repl-main" 'comment nil))))

(ert-deftest consent-repl-stream-chrome-condition-marker ()
  "A recoverable condition renders under a human chrome."
  (should (string-match-p
           (regexp-quote ";;   !! ")
           (consent-repl-stream-rendered-from-string
            "undefined-name\n" "repl-main" 'comment nil))))

(ert-deftest consent-repl-stream-chrome-program-output ()
  "`comment' owns program output (commented, on the control channel); every\
 other
chrome leaves it raw on its own stream.  Matches the portable renderer, and the
comment transcript still replays."
  (let ((prelude "(import (scheme base) (scheme write))\n"))
    ;; A printed line becomes an aligned `;; :: ' comment before the result, on
    ;; the control channel.
    (should (equal (consent-repl-stream-rendered-from-string
                    (concat prelude "(display \"hi\\n\")\n(+ 1 1)\n")
                    "repl-main" 'comment nil)
                   (concat
                    "#| 1 |# (import (scheme base) (scheme write))\n"
                    ";;   => (unspecified)\n;;\n"
                    "#| 2 |# (display \"hi\\n\")\n;;   :: hi\n"
                    ";;   => (unspecified)\n;;\n"
                    "#| 3 |# (+ 1 1)\n;;   => 2\n;;\n"
                    "#| 4 |# ;;   __ exit closed-ok\n")))
    ;; Because `comment' owns it, the raw program-output stream is empty.
    (should (equal (cdr (consent-repl-stream-capture-from-string
                         (concat prelude "(display \"hi\\n\")\n(+ 1 1)\n")
                         "repl-main" 'comment nil))
                   ""))
    ;; Multi-line output is one comment per line; a missing trailing newline
    ;; gains
    ;; one so the comment closes before the result.
    (should (string-match-p
             (regexp-quote ";;   :: a\n;;   :: b\n;;   => 0")
             (consent-repl-stream-rendered-from-string
              (concat prelude
                      "(begin (display \"a\")(newline)(display \"b\")(newline)\
 0)\n")
              "repl-main" 'comment nil)))
    (should (string-match-p
             (regexp-quote ";;   :: x\n;;   => 5")
             (consent-repl-stream-rendered-from-string
              (concat prelude "(begin (display \"x\") 5)\n")
              "repl-main" 'comment nil)))
    ;; `classic' leaves program output raw on its own stream (the printed value
    ;; 12321 is computed so it is absent from the echoed source); the control
    ;; channel carries records only.
    (let ((classic (consent-repl-stream-capture-from-string
                    (concat prelude
                      "(begin (display (* 111 111))(newline) 1)\n")
                    "repl-main" 'classic nil)))
      (should (equal (cdr classic) "12321\n"))
      (should-not (string-match-p "12321" (car classic))))
    ;; The comment control-channel transcript round-trips: commented output is
    ;; inert on replay and the re-evaluated forms regenerate it, so results
    ;; match.
    (let* ((input (concat prelude
                          "(display \"hello\\n\")\n"
                          "(begin (display \"x\")(newline) 42)\n(+ 2 3)\n"))
           (transcript (consent-repl-stream-rendered-from-string
                        input "repl-main" 'comment nil)))
      (should (equal (consent-repl-stream-test--result-displays
                      (consent-repl-stream-records-from-string transcript
                        "repl-main"))
                     (consent-repl-stream-test--result-displays
                      (consent-repl-stream-records-from-string
                       input "repl-main")))))))

(ert-deftest consent-repl-stream-chrome-faces-realize-roles ()
  "Faces are applied when requested and absent from the plain rendering."
  (let ((faced (consent-repl-stream-rendered-from-string
                "(+ 1 2)\n" "repl-main" 'comment t))
        (plain (consent-repl-stream-rendered-from-string
                "(+ 1 2)\n" "repl-main" 'comment nil)))
    ;; Faces are presentation only: stripping them recovers the plain text.
    (should (equal (substring-no-properties faced) plain))
    (should (text-property-not-all 0 (length faced) 'face nil faced))
    (should-not (text-property-not-all 0 (length plain) 'face nil plain))
    ;; A colored role realizes its dedicated face; the neutral result value
    ;; stays unfaced, mirroring the portable renderer leaving it uncolored.
    (let ((marker (string-match-p (regexp-quote "=> ") faced)))
      (should (eq (get-text-property marker 'face faced)
                  'consent-repl-chrome-result-marker)))))

;;;; Transcript capture and replay (docs/repl-interaction-contract.md)

(defun consent-repl-stream-test--serialize (records)
  "Serialize RECORDS through the consent writer for a host-portable stream\
 compare."
  (mapcar #'consent-result->external records))

(defun consent-repl-stream-test--group (record name)
  "Return the sub-list (NAME ...) of RECORD whose tag name is NAME, or nil."
  (seq-find (lambda (entry)
              (and (consp entry)
                   (equal (consent-repl-stream-test--sym (car entry)) name)))
            (cdr-safe record)))

(ert-deftest consent-repl-stream-replay-reload-and-replay ()
  "A captured transcript serializes, reloads, and replays to the same stream."
  (let* ((captured (consent-repl-stream-test--drive
                    "(define base 7)\n(* base 3)\n"))
         (text (mapconcat (lambda (r) (concat (consent-result->external r)
           "\n"))
                          captured ""))
         (reloaded (consent-repl-stream-records-from-datum-stream text)))
    (should (= (length reloaded) (length captured)))
    (should (equal (consent-repl-stream-submissions-from-records reloaded)
                   '("(define base 7)" "(* base 3)")))
    ;; Replaying the reloaded transcript reproduces the captured record stream.
    (should (equal (consent-repl-stream-test--serialize
                    (consent-repl-stream-replay-records reloaded
                      "project-main"))
                   (consent-repl-stream-test--serialize captured)))))

(ert-deftest consent-repl-stream-replay-skips-incomplete ()
  "An EOF-truncated partial form is not a replayable submission."
  (should-not (consent-repl-stream-submissions-from-records
               (consent-repl-stream-test--drive "(+ 1\n"))))

(ert-deftest consent-repl-stream-replay-pure-roundtrip ()
  "A pure transcript replays to an equal record stream and the report says so."
  (let* ((captured (consent-repl-stream-test--drive
                    "(import (scheme base))\n(define base 20)\n(* base 3)\n"))
         (replayed (consent-repl-stream-replay-records captured
           "project-main"))
         (report (consent-repl-stream-replay-report captured replayed)))
    (should (equal (consent-repl-stream-replay-input captured)
                   "(import (scheme base))\n(define base 20)\n(* base 3)\n"))
    (should (equal (consent-repl-stream-test--serialize replayed)
                   (consent-repl-stream-test--serialize captured)))
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field report "status"))
                   "reproduced"))
    (should-not (consent-repl-stream-test--field report "divergences"))
    (should (= (consent-repl-stream-test--int
                (consent-repl-stream-test--field report "submissions"))
               3))))

(ert-deftest consent-repl-stream-replay-effect-fails-closed ()
  "A live host effect that succeeded under capture authority fails closed on a
weaker replay posture, and the report records that divergence rather than
silently reproducing the recorded value."
  (let* ((captured (consent-repl-stream-test--drive
                    (concat "(import (scheme base) (scheme repl))\n"
                            "(interaction-environment)\n")))
         (replayed (consent-repl-stream-replay-records
                    captured "project-main"
                    '(:policy-actions ((standard-host-effect . deny)))))
         (report (consent-repl-stream-replay-report captured replayed)))
    ;; Capture: both forms succeeded (two results, no conditions).
    (should (= (consent-repl-stream-test--count captured "repl-result") 2))
    (should (= (consent-repl-stream-test--count captured "repl-condition") 0))
    ;; Replay denied the effect: the interaction-environment form is a
    ;; condition.
    (should (= (consent-repl-stream-test--count replayed "repl-result") 1))
    (should (= (consent-repl-stream-test--count replayed "repl-condition") 1))
    ;; The report flags the result -> condition divergence with its source.
    (should (equal (consent-repl-stream-test--sym
                    (consent-repl-stream-test--field report "status"))
                   "diverged"))
    (let ((divergence (car (consent-repl-stream-test--field
                            report "divergences"))))
      (should (equal (consent-repl-stream-test--field divergence "source")
                     "(interaction-environment)"))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field
                       (consent-repl-stream-test--group divergence "captured")
                       "kind"))
                     "result"))
      (should (equal (consent-repl-stream-test--sym
                      (consent-repl-stream-test--field
                       (consent-repl-stream-test--group divergence "replayed")
                       "kind"))
                     "condition")))))

;;;; Scheme-callable session switching redirects forms across sandboxes

(ert-deftest consent-repl-stream-session-switch-redirects-and-isolates ()
  "A `switch-session' verb redirects subsequent forms to per-session\
 sandboxes."
  (consent-session-clear!)
  (setq consent-session-current-id nil)
  (let* ((records
          (consent-repl-stream-test--drive
           (concat
            "(import (agent session))\n"
            "(create-session 'named '((id sess-a)))\n"
            "(create-session 'named '((id sess-b)))\n"
            "(switch-session 'sess-a)\n"
            "(import (agent session))\n"
            "(define v 'a)\n"
            "v\n"
            "(switch-session 'sess-b)\n"
            "(import (agent session))\n"
            "(define v 'b)\n"
            "v\n"
            "(switch-session 'sess-a)\n"
            "v\n")
           '(:policy-actions ((window-session . allow)))))
         (results (consent-repl-stream-test--of records "repl-result")))
    ;; Thirteen forms produce thirteen results; `v' reads the value defined in
    ;; whichever session is current, and switching back to `sess-a' still sees
    ;; its own `v' (isolation), not the value defined in `sess-b'.
    (should (= (length results) 13))
    (should (equal (consent-repl-stream-test--field (nth 6 results) "display")
                   "a"))
    (should (equal (consent-repl-stream-test--field (nth 10 results) "display")
                   "b"))
    (should (equal (consent-repl-stream-test--field (nth 12 results) "display")
                   "a"))
    (should (= (consent-repl-stream-test--count records "repl-condition") 0))))

(provide 'consent-repl-stream-test)

;;; consent-repl-stream-test.el ends here
