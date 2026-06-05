;;; Portable terminal REPL shell tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; terminal REPL shell (cli repl-shell) against the cross-host REPL interaction
;;; contract (docs/repl-interaction-contract.md) without loading the Emacs host
;;; adapter.  It asserts the emitted record vocabulary, durable session
;;; evaluation, recoverable conditions, EOF/exit close status, policy-gated
;;; effects, and program-output/record stream separation.

(import (scheme base)
        (scheme write)
        (cli repl-shell))

;; Count failed checks so the portable runner can report all mismatches.
(define failures 0)

;; Record one failed check and keep running the rest of the portable test file.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal?.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Assert VALUE is true after normalizing to canonical booleans.
(define (check-true name value)
  (check name (if value #t #f) #t))

;; Assert VALUE is false after normalizing to canonical booleans.
(define (check-false name value)
  (check name (if value #t #f) #f))

;;;; Record helpers

;; Return the single value of field NAME in tagged list DATUM, or #f.
(define (field datum name)
  (let ((entry (assq name (cdr datum))))
    (and entry (pair? (cdr entry)) (cadr entry))))

;; Return the record kind (the leading tag symbol) of RECORD.
(define (kind record)
  (and (pair? record) (car record)))

;; Return the records in RECORDS whose kind is TAG, in order.
(define (records-of records tag)
  (let loop ((records records) (collected '()))
    (cond
     ((null? records) (reverse collected))
     ((eq? (kind (car records)) tag)
      (loop (cdr records) (cons (car records) collected)))
     (else (loop (cdr records) collected)))))

;; Return the number of records in RECORDS whose kind is TAG.
(define (count-of records tag)
  (length (records-of records tag)))

;; Drive INPUT under SESSION and return the contract records.
(define (drive input . options)
  (apply cli-repl-records-from-string input "project-main" options))

;;;; Simple expression evaluation through the runtime writer/result path

(let ((records (drive "(+ 1 2)\n")))
  (let ((result (car (records-of records 'repl-result))))
    (check 'simple-eval-display (field result 'display) "3")
    (check 'simple-eval-submission (field result 'submission) 'sub-1)
    (let ((evaluation (field result 'evaluation-result)))
      (check-true 'simple-eval-wraps-evaluation-result
                  (and (pair? evaluation)
                       (eq? (car evaluation) 'evaluation-result)))
      (check 'simple-eval-status (field evaluation 'status) 'ok)))
  ;; The first prompt is a ready primary prompt; exactly one exit closes cleanly.
  (let ((prompt (car (records-of records 'repl-prompt))))
    (check 'simple-eval-prompt-state (field prompt 'state) 'ready)
    (check 'simple-eval-prompt-pending (field prompt 'pending) #f)
    (check 'simple-eval-prompt-ordinal (field prompt 'ordinal) 1))
  (check 'simple-eval-one-exit (count-of records 'repl-exit) 1)
  (let ((exit (car (records-of records 'repl-exit))))
    (check 'simple-eval-exit-reason (field exit 'reason) 'eof)
    (check 'simple-eval-exit-status (field exit 'status) 'closed-ok)
    (check 'simple-eval-exit-count (field exit 'count) 1)))

;;;; Definitions, imports, and macros persist across submissions

(let ((records
       (drive
        (string-append
         "(import (scheme base))\n"
         "(define base 20)\n"
         "(define-syntax inc (syntax-rules () ((_ v) (+ v 1))))\n"
         "(inc base)\n"))))
  (let ((results (records-of records 'repl-result)))
    (check 'persist-result-count (length results) 4)
    ;; The fourth submission uses the macro and the earlier definition.
    (check 'persist-macro-and-definition
           (field (list-ref results 3) 'display)
           "21"))
  (check 'persist-no-conditions (count-of records 'repl-condition) 0))

;;;; Session-gated interaction-environment resolves inside the session

(let ((records
       (drive
        (string-append
         "(import (scheme base) (scheme eval) (scheme repl))\n"
         "(eval (quote (define made 5)) (interaction-environment))\n"
         "made\n"))))
  (let ((results (records-of records 'repl-result)))
    (check 'interaction-environment-value
           (field (list-ref results 2) 'display)
           "5"))
  (check 'interaction-environment-no-conditions
         (count-of records 'repl-condition) 0))

;;;; A recoverable evaluator condition keeps the session open

(let ((records (drive "undefined-name\n(+ 4 5)\n")))
  (let ((condition (car (records-of records 'repl-condition))))
    (check 'eval-condition-phase (field condition 'phase) 'eval)
    (check 'eval-condition-recoverable (field condition 'recoverable) #t)
    (check 'eval-condition-submission (field condition 'submission) 'sub-1))
  ;; The session keeps running: the following form still evaluates.
  (let ((result (car (records-of records 'repl-result))))
    (check 'eval-condition-session-continues (field result 'display) "9"))
  (check 'eval-condition-clean-close
         (field (car (records-of records 'repl-exit)) 'status)
         'closed-ok))

;;;; A recoverable reader condition keeps the session open

(let ((records (drive ")\n(+ 6 7)\n")))
  (let ((condition (car (records-of records 'repl-condition))))
    (check 'read-condition-phase (field condition 'phase) 'read)
    (check 'read-condition-recoverable (field condition 'recoverable) #t))
  (let ((result (car (records-of records 'repl-result))))
    (check 'read-condition-session-continues (field result 'display) "13")))

;;;; An incomplete form is continued, not reported as a hard error

(let ((records (drive "(+ 1\n2)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (check 'continuation-second-prompt-state
           (field (list-ref prompts 1) 'state) 'continuation)
    (check 'continuation-second-prompt-pending
           (field (list-ref prompts 1) 'pending) #t)
    (check 'continuation-keeps-ordinal
           (field (list-ref prompts 1) 'ordinal) 1))
  (let ((submission (car (records-of records 'repl-submission))))
    (check 'continuation-submission-complete (field submission 'complete) #t)
    (check 'continuation-submission-source (field submission 'source) "(+ 1\n2)"))
  (check 'continuation-result (field (car (records-of records 'repl-result))
                                     'display)
         "3"))

;;;; EOF mid-form closes with the documented error status

(let ((records (drive "(+ 1\n")))
  (let ((submission (car (records-of records 'repl-submission))))
    (check 'eof-incomplete-submission-complete (field submission 'complete) #f)
    (check 'eof-incomplete-submission-eof (field submission 'eof) #t))
  (let ((condition (car (records-of records 'repl-condition))))
    (check 'eof-incomplete-condition-phase (field condition 'phase) 'read)
    (check 'eof-incomplete-condition-unrecoverable
           (field condition 'recoverable) #f))
  (let ((exit (car (records-of records 'repl-exit))))
    (check 'eof-incomplete-exit-reason (field exit 'reason) 'eof)
    (check 'eof-incomplete-exit-status (field exit 'status) 'closed-error)))

;;;; Explicit exit closes with the explicit reason and clean status

(let ((records (drive "(+ 1 2)\n(exit)\n")))
  (check 'explicit-exit-one-exit (count-of records 'repl-exit) 1)
  (let ((exit (car (records-of records 'repl-exit))))
    (check 'explicit-exit-reason (field exit 'reason) 'explicit)
    (check 'explicit-exit-status (field exit 'status) 'closed-ok)
    (check 'explicit-exit-count (field exit 'count) 2)))

;;;; Default policy denies an ungranted host effect, fail closed

(let ((records
       (drive
        "(begin (import (scheme file)) (open-output-file \"/tmp/consent-repl-denied\"))\n")))
  (let ((condition (car (records-of records 'repl-condition))))
    (check 'policy-denied-phase (field condition 'phase) 'eval)
    (check 'policy-denied-recoverable (field condition 'recoverable) #t)
    (let ((datum (field condition 'condition)))
      (check 'policy-denied-type (field datum 'type) 'policy-denial)))
  ;; A denied effect does not crash the loop; the session still closes cleanly.
  (check 'policy-denied-clean-close
         (field (car (records-of records 'repl-exit)) 'status)
         'closed-ok))

;;;; A session-policy denial of interaction-environment fails closed

(let ((records
       (drive
        (string-append
         "(import (scheme base) (scheme repl))\n"
         "(interaction-environment)\n")
        '((policy-actions . ((standard-host-effect . deny)))))))
  (let ((condition (car (records-of records 'repl-condition))))
    (check 'denied-interaction-environment-phase (field condition 'phase) 'eval)
    (let ((datum (field condition 'condition)))
      (check 'denied-interaction-environment-type
             (field datum 'type) 'policy-denial))))

;;;; Program output is separated from the interaction record stream

(let ((records '())
      (output '()))
  (let* ((lines (list "(import (scheme base) (scheme write))\n"
                      "(display \"emitted\")\n"
                      "(+ 1 2)\n"
                      "(exit)\n"))
         (read-chunk
          (lambda ()
            (if (null? lines)
                (eof-object)
                (let ((line (car lines))) (set! lines (cdr lines)) line))))
         (exit-code
          (cli-repl-run
           read-chunk
           (lambda (record) (set! records (cons record records)))
           (lambda (text) (set! output (cons text output)))
           "project-main")))
    (check 'stream-separation-exit-code exit-code 0)
    ;; Program output reached the program-output stream...
    (check 'stream-separation-program-output
           (apply string-append (reverse output)) "emitted")
    ;; ...and the record stream carries only contract records (one per evaluated
    ;; submission: import, display, and the sum), never the program output text.
    (let ((records (reverse records)))
      (check 'stream-separation-result-count
             (count-of records 'repl-result) 3)
      (check-true 'stream-separation-has-exit
                  (> (count-of records 'repl-exit) 0)))))

(if (> failures 0)
    (error "portable terminal REPL tests failed" failures))
