;;; consent-repl-comint-test.el --- Live comint REPL buffer tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Coverage for the live, interactive Consent Scheme REPL buffer
;; (`consent-repl-comint'), the in-editor comint surface onto a durable session.
;; These tests drive the buffer the way a user does -- typing at the prompt and
;; pressing RET -- and assert the chrome-rendered transcript, the contract record
;; vocabulary (through the always-reachable `datum' chrome), durable session
;; evaluation shared with the other Emacs eval paths, multi-line continuation,
;; recoverable conditions, EOF/exit close status, and program-input multiplexing
;; over the shared stdin cursor (#505).  They also assert the existing eval
;; surfaces are undisturbed, per the issue's strictly-additive contract.

;;; Code:

(require 'ert)
(require 'seq)
(require 'consent-eval)
(require 'consent-repl)
(require 'consent-repl-chrome)
(require 'consent-repl-comint)
(require 'consent-repl-stream)
(require 'consent-result)
(require 'consent-session)

;;;; Fixtures

(defvar consent-repl-comint-test--counter 0
  "Monotonic counter giving each test a fresh session id.")

(defun consent-repl-comint-test--fresh-id ()
  "Return a unique session id so tests do not share durable state."
  (setq consent-repl-comint-test--counter
        (1+ consent-repl-comint-test--counter))
  (format "comint-test-%d" consent-repl-comint-test--counter))

(defun consent-repl-comint-test--submit (buffer text)
  "Type TEXT at BUFFER's prompt and press RET as `consent-repl-comint-return'."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (consent-repl-comint-return)))

(defun consent-repl-comint-test--text (buffer)
  "Return BUFFER's full text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro consent-repl-comint-test--with-buffer (var &rest body)
  "Open a fresh live REPL buffer bound to VAR, run BODY, then kill the buffer.
The session id is bound to `id' for sharing assertions."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((id (consent-repl-comint-test--fresh-id))
          (,var (consent-repl-comint id)))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p ,var)
         (kill-buffer ,var)))))

;;;; Simple evaluation and the live prompt

(ert-deftest consent-repl-comint-simple-evaluation ()
  "Typing a form and pressing RET evaluates it and renders the result inline."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(+ 1 2)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "=> 3" text))
      ;; The submission echo is the user's typed text, not a second chrome echo.
      (should (string-match-p (regexp-quote "(+ 1 2)") text)))
    (with-current-buffer buffer
      ;; Ordinal advanced past the evaluated submission; session stays open.
      (should (= consent-repl-comint--ordinal 2))
      (should (= consent-repl-comint--count 1))
      (should-not consent-repl-comint--closed))))

(ert-deftest consent-repl-comint-prompt-is-read-only ()
  "The rendered prompt is read only so editing happens only in the input region."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer
      (should (get-text-property (point-min) 'read-only)))))

;;;; Durable session shared with the other Emacs eval paths

(ert-deftest consent-repl-comint-shares-session-with-eval-paths ()
  "Definitions cross between the live buffer and `consent-session-eval-source'."
  (consent-repl-comint-test--with-buffer buffer
    ;; Defined in the live buffer ...
    (consent-repl-comint-test--submit buffer "(define answer 41)")
    ;; ... is visible to the session the other Emacs eval paths drive.
    (should (equal (consent-value->external
                    (consent-session-eval-source id "answer"))
                   "41"))
    ;; Defined through the session ...
    (consent-session-eval-source id "(define via-session 99)")
    ;; ... is visible back in the live buffer.
    (consent-repl-comint-test--submit buffer "(+ answer via-session)")
    (should (string-match-p "=> 140"
                            (consent-repl-comint-test--text buffer)))))

(ert-deftest consent-repl-comint-macros-persist-across-submissions ()
  "Imports and macros introduced in one submission are visible to later ones."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(import (scheme base))")
    (consent-repl-comint-test--submit
     buffer "(define-syntax twice (syntax-rules () ((_ e) (+ e e))))")
    (consent-repl-comint-test--submit buffer "(twice 21)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "=> 42" text))
      (should-not (string-match-p "!!" text)))))

;;;; Multi-line continuation

(ert-deftest consent-repl-comint-incomplete-form-continues ()
  "An incomplete form is not evaluated; it keeps pending with a continuation gutter."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(+ 1")
    (with-current-buffer buffer
      ;; Nothing was evaluated: ordinal unchanged, no result rendered.
      (should (= consent-repl-comint--ordinal 1))
      (should (= consent-repl-comint--count 0))
      (should-not (string-match-p "=>" (buffer-string)))
      ;; The continuation gutter is shown as a non-editable line prefix.
      (should (stringp (get-text-property (1- (point-max)) 'line-prefix))))
    ;; Completing the form submits the whole thing.
    (consent-repl-comint-test--submit buffer "2)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "=> 3" text)))
    (with-current-buffer buffer
      (should (= consent-repl-comint--count 1)))))

(ert-deftest consent-repl-comint-continuation-gutter-carries-nesting ()
  "A deeper continuation gutter renders the still-open construct count."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(list (vector 1")
    (with-current-buffer buffer
      (let ((gutter (get-text-property (1- (point-max)) 'line-prefix)))
        (should (stringp gutter))
        (should (string-match-p "2" gutter))))))

;;;; Recoverable conditions keep the session open

(ert-deftest consent-repl-comint-recoverable-condition-keeps-session ()
  "A recoverable evaluator condition is rendered and the session keeps running."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "this-is-unbound")
    (with-current-buffer buffer
      (should (string-match-p "!!" (buffer-string)))
      (should-not consent-repl-comint--closed))
    ;; The next submission still evaluates in the same live session.
    (consent-repl-comint-test--submit buffer "(+ 2 2)")
    (should (string-match-p "=> 4" (consent-repl-comint-test--text buffer)))))

(ert-deftest consent-repl-comint-recoverable-reader-condition ()
  "A malformed datum is reported as a reader condition without closing the session."
  (consent-repl-comint-test--with-buffer buffer
    ;; A lone closing paren is a malformed datum the driver reports.
    (consent-repl-comint-test--submit buffer ")")
    (with-current-buffer buffer
      (should (string-match-p "!!" (buffer-string)))
      (should-not consent-repl-comint--closed))))

;;;; EOF and explicit exit close with the documented status

(ert-deftest consent-repl-comint-exit-form-closes-session ()
  "An explicit `(exit)' closes with `(reason explicit) (status closed-ok)'.
The close-status vocabulary is asserted on the raw `repl-exit' record through the
`datum' chrome, since the `comment' chrome drops the reason and detail fields."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer (consent-repl-comint-set-chrome 'datum))
    (consent-repl-comint-test--submit buffer "(exit)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "(reason explicit)" text))
      (should (string-match-p "(status closed-ok)" text)))
    (with-current-buffer buffer
      (should consent-repl-comint--closed)
      (let ((ordinal consent-repl-comint--ordinal)
            (count consent-repl-comint--count))
        ;; A submission after close is inert: no eval, frozen state.
        (consent-repl-comint-test--submit buffer "(+ 1 1)")
        (should-not (string-match-p "(value 2)"
                                    (consent-repl-comint-test--text buffer)))
        (should consent-repl-comint--closed)
        (should (= ordinal consent-repl-comint--ordinal))
        (should (= count consent-repl-comint--count))))))

(ert-deftest consent-repl-comint-exit-with-error-status ()
  "An exit carrying a nonzero object closes `closed-error' with the object as detail."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer (consent-repl-comint-set-chrome 'datum))
    (consent-repl-comint-test--submit buffer "(exit 7)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "(reason explicit)" text))
      (should (string-match-p "(status closed-error)" text))
      (should (string-match-p (regexp-quote "(detail \"7\")") text)))
    (with-current-buffer buffer (should consent-repl-comint--closed))))

(ert-deftest consent-repl-comint-send-eof-closes-clean ()
  "`consent-repl-comint-send-eof' at a fresh prompt closes `(reason eof) closed-ok'."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer (consent-repl-comint-set-chrome 'datum))
    (consent-repl-comint-test--submit buffer "(+ 1 1)")
    (with-current-buffer buffer (consent-repl-comint-send-eof))
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "(reason eof)" text))
      (should (string-match-p "(status closed-ok)" text)))
    (with-current-buffer buffer (should consent-repl-comint--closed))))

(ert-deftest consent-repl-comint-send-eof-unterminated-is-error ()
  "EOF with a buffered partial form closes `closed-error' with a read condition.
Mirrors the engine's EOF-mid-form handling rather than closing `closed-ok'."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer
      (consent-repl-comint-set-chrome 'datum)
      ;; A partial form sits unsubmitted in the input region.
      (goto-char (point-max))
      (insert "(+ 1")
      (consent-repl-comint-send-eof))
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "(repl-condition" text))
      (should (string-match-p "(phase read)" text))
      (should (string-match-p "(reason eof)" text))
      (should (string-match-p "(status closed-error)" text))
      (should (string-match-p "unterminated form at end of input" text)))
    (with-current-buffer buffer (should consent-repl-comint--closed))))

(ert-deftest consent-repl-comint-send-eof-evaluates-buffered-complete ()
  "EOF with a buffered complete form evaluates it before closing `closed-ok'."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "(* 6 7)")
      (consent-repl-comint-send-eof))
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "=> 42" text)))
    (with-current-buffer buffer (should consent-repl-comint--closed))))

;;;; Forced send (C-j) of an incomplete form reports and resyncs

(ert-deftest consent-repl-comint-force-send-incomplete-reports-condition ()
  "`consent-repl-comint-send-input' on an incomplete form reports a read condition.
The session stays open and a subsequent complete form still evaluates."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "(+ 1")
      (consent-repl-comint-send-input))
    (with-current-buffer buffer
      (should (string-match-p "!!" (buffer-string)))
      (should-not consent-repl-comint--closed)
      ;; The incomplete form is reported, not counted as an evaluated submission.
      (should (= consent-repl-comint--count 0)))
    (consent-repl-comint-test--submit buffer "(+ 2 3)")
    (with-current-buffer buffer
      (should (string-match-p "=> 5" (buffer-string)))
      (should (= consent-repl-comint--count 1)))))

;;;; Reopening a closed buffer revives the session

(ert-deftest consent-repl-comint-reopen-after-close-revives ()
  "Reissuing `consent-repl-comint' on a closed buffer reopens the same session."
  (let ((id (consent-repl-comint-test--fresh-id)))
    (let ((buffer (consent-repl-comint id)))
      (unwind-protect
          (progn
            (consent-repl-comint-test--submit buffer "(define kept 8)")
            (with-current-buffer buffer (consent-repl-comint-send-eof))
            (with-current-buffer buffer (should consent-repl-comint--closed))
            ;; Reopen: same buffer, same session, revived.
            (should (eq buffer (consent-repl-comint id)))
            (with-current-buffer buffer (should-not consent-repl-comint--closed))
            ;; State persisted across the reopen.
            (consent-repl-comint-test--submit buffer "(* kept 2)")
            (with-current-buffer buffer
              (should (string-match-p "=> 16" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;;;; The canonical datum chrome stays reachable

(ert-deftest consent-repl-comint-datum-chrome-reachable ()
  "Switching to the `datum' chrome renders the canonical contract record stream."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer
      (consent-repl-comint-set-chrome 'datum))
    (consent-repl-comint-test--submit buffer "(+ 2 3)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "(repl-submission" text))
      (should (string-match-p "(repl-result" text))
      (should (string-match-p "(evaluation-result (status ok)" text)))))

;;;; Multiple forms in one submission, evaluated in order

(ert-deftest consent-repl-comint-multiple-forms-one-submission ()
  "Several complete forms in one input evaluate in order, one result each."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(+ 1 1) (* 3 3)")
    (let ((text (consent-repl-comint-test--text buffer)))
      (should (string-match-p "=> 2" text))
      (should (string-match-p "=> 9" text)))
    (with-current-buffer buffer
      (should (= consent-repl-comint--count 2)))))

;;;; Program input over the shared stdin cursor (#505)

(ert-deftest consent-repl-comint-program-input-from-queue ()
  "An evaluated `read-line' consumes seeded program input over the shared cursor."
  (consent-repl-comint-test--with-buffer buffer
    (with-current-buffer buffer
      (setq consent-repl-comint--input-queue (list "typed line\n")))
    (consent-repl-comint-test--submit
     buffer "(begin (import (scheme base)) (read-line))")
    (should (string-match-p (regexp-quote "\"typed line\"")
                            (consent-repl-comint-test--text buffer)))))

(ert-deftest consent-repl-comint-program-input-same-line-remainder ()
  "Text after a reading form on the same line is consumed as program data."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit
     buffer "(begin (import (scheme base)) (read-line)) same-line-data")
    (should (string-match-p (regexp-quote "\" same-line-data\"")
                            (consent-repl-comint-test--text buffer)))))

;;;; Multi-line form history is a single, gutter-free ring entry

(ert-deftest consent-repl-comint-multiline-form-single-history-entry ()
  "A continued multi-line form lands in the input ring as one gutter-free entry."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(list 1")   ; incomplete: continues
    (consent-repl-comint-test--submit buffer "2 3)")      ; completes and submits
    (with-current-buffer buffer
      (should (string-match-p "=> (1 2 3)" (buffer-string)))
      (let ((entry (ring-ref comint-input-ring 0)))
        ;; The whole multi-line form is one entry, not split per line.
        (should (string-match-p "(list 1" entry))
        (should (string-match-p "2 3)" entry))
        (should (string-match-p "\n" entry))
        ;; The continuation gutter never leaked into the recorded input.
        (should-not (text-property-not-all 0 (length entry)
                                           'line-prefix nil entry))))))

;;;; Macros and imports cross the comint<->session bridge in both directions

(ert-deftest consent-repl-comint-macros-shared-bidirectionally ()
  "A macro defined in the live buffer is usable via the session, and vice versa."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(import (scheme base))")
    ;; Defined in the live buffer ...
    (consent-repl-comint-test--submit
     buffer "(define-syntax sq (syntax-rules () ((_ x) (* x x))))")
    ;; ... usable through the session the other eval paths drive.
    (should (equal (consent-value->external
                    (consent-session-eval-source id "(sq 5)"))
                   "25"))
    ;; Defined through the session ...
    (consent-session-eval-source
     id "(define-syntax cube (syntax-rules () ((_ x) (* x x x))))")
    ;; ... usable back in the live buffer.
    (consent-repl-comint-test--submit buffer "(cube 2)")
    (should (string-match-p "=> 8" (consent-repl-comint-test--text buffer)))))

;;;; Strictly additive: existing eval surfaces are undisturbed

(ert-deftest consent-repl-comint-leaves-stream-entry-intact ()
  "The batch/scripted incremental stream entry still drives independently."
  (let ((records (consent-repl-stream-records-from-string
                  "(+ 10 20)\n" "stream-untouched")))
    (should (= (length (seq-filter
                        (lambda (r)
                          (and (consp r) (consent-symbol-p (car r))
                               (equal (consent-symbol-name (car r)) "repl-result")))
                        records))
               1))))

(ert-deftest consent-repl-comint-session-eval-after-live-buffer ()
  "`consent-session-eval-source' keeps working on a session a live buffer used."
  (consent-repl-comint-test--with-buffer buffer
    (consent-repl-comint-test--submit buffer "(define shared 5)")
    ;; The original session-source eval path is unchanged and signals on error.
    (should (equal (consent-value->external
                    (consent-session-eval-source id "(* shared 4)"))
                   "20"))))

(provide 'consent-repl-comint-test)

;;; consent-repl-comint-test.el ends here
