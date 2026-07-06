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
        (only (consent reader)
              consent-datum->external
              consent-number-value)
        (cli repl-shell)
        (cli repl-chrome))

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
    (check 'simple-eval-prompt-ordinal
           (consent-number-value (field prompt 'ordinal)) 1))
  (check 'simple-eval-one-exit (count-of records 'repl-exit) 1)
  (let ((exit (car (records-of records 'repl-exit))))
    (check 'simple-eval-exit-reason (field exit 'reason) 'eof)
    (check 'simple-eval-exit-status (field exit 'status) 'closed-ok)
    (check 'simple-eval-exit-count
           (consent-number-value (field exit 'count)) 1)))

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

(let ((records (drive (string-append
                       "(define (uses-missing-helper value)\n"
                       "  (missing-helper value))\n"
                       "(uses-missing-helper '(a b))\n"))))
  (let* ((condition-record (car (records-of records 'repl-condition)))
         (condition (field condition-record 'condition)))
    (check 'unbound-identifier-display-names-symbol
           (field condition-record 'display)
           "consent eval error: unbound identifier: missing-helper")
    (check 'unbound-identifier-condition-symbol
           (field condition 'symbol)
           'missing-helper)))

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
           (consent-number-value (field (list-ref prompts 1) 'ordinal)) 1))
  (let ((submission (car (records-of records 'repl-submission))))
    (check 'continuation-submission-complete (field submission 'complete) #t)
    (check 'continuation-submission-source (field submission 'source) "(+ 1\n2)"))
  (check 'continuation-result (field (car (records-of records 'repl-result))
                                     'display)
         "3"))

;;;; Blank ready-prompt input redraws a same-ordinal ready prompt

(let ((records (drive "\n(+ 1 2)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (check 'blank-ready-prompt-count (length prompts) 3)
    (check 'blank-ready-first-state (field (list-ref prompts 0) 'state) 'ready)
    (check 'blank-ready-second-state (field (list-ref prompts 1) 'state) 'ready)
    (check 'blank-ready-third-state (field (list-ref prompts 2) 'state) 'ready)
    (check 'blank-ready-first-ordinal
           (consent-number-value (field (list-ref prompts 0) 'ordinal)) 1)
    (check 'blank-ready-second-ordinal
           (consent-number-value (field (list-ref prompts 1) 'ordinal)) 1)
    (check 'blank-ready-third-ordinal
           (consent-number-value (field (list-ref prompts 2) 'ordinal)) 2))
  (check 'blank-ready-submission-count
         (count-of records 'repl-submission) 1)
  (check 'blank-ready-result
         (field (car (records-of records 'repl-result)) 'display)
         "3"))

;;;; The continuation prompt carries the reader's pending-nesting indicator

;; The depth narrows as constructs close (two open lists, then one), the kind
;; names the innermost pending construct, and a ready prompt omits both fields.
(let ((records (drive "(+ (* 2\n3)\n4)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (check 'nesting-ready-prompt-omits-field
           (field (list-ref prompts 0) 'nesting) #f)
    (check 'nesting-depth-two
           (consent-number-value (field (list-ref prompts 1) 'nesting)) 2)
    (check 'nesting-kind-list
           (field (list-ref prompts 1) 'pending-kind) 'list)
    (check 'nesting-narrows-to-one
           (consent-number-value (field (list-ref prompts 2) 'nesting)) 1)))

;; An unterminated string is the innermost pending construct even inside a
;; list, so a chrome can distinguish "inside a string" from list nesting.
(let ((records (drive "(string-length \"a\nb\")\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (check 'nesting-string-depth
           (consent-number-value (field (list-ref prompts 1) 'nesting)) 2)
    (check 'nesting-string-kind
           (field (list-ref prompts 1) 'pending-kind) 'string)))

;; A pending datum prefix (a lone quote) keeps the session continuing with an
;; empty construct stack: depth zero and the `datum' pending kind.
(let ((records (drive "'\n1\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (check 'nesting-datum-prefix-depth
           (consent-number-value (field (list-ref prompts 1) 'nesting)) 0)
    (check 'nesting-datum-prefix-kind
           (field (list-ref prompts 1) 'pending-kind) 'datum))
  (check 'nesting-datum-prefix-result
         (field (car (records-of records 'repl-result)) 'display)
         "1"))

;;;; The continuation prompt is emitted before the read it requests

;; A continuation gutter is a request for more input, so it must be emitted (and
;; flushed) *before* the blocking read that supplies the continued line -- on a
;; live TTY a prompt emitted after the read would land glued to the next result
;; line instead of fronting the continued input.  The record-stream order alone
;; cannot capture this: a fully-buffered string never blocks, so the emission
;; order of records is identical either way.  Instrument the read/emit
;; interleaving directly -- log each chunk read alongside the continuation prompt
;; -- and assert exactly one chunk is read before the prompt is emitted.
(let* ((chunks (list "(+ 1\n" "2)\n"))
       (events '())
       (note (lambda (event) (set! events (cons event events))))
       (read-chunk
        (lambda ()
          (if (null? chunks)
              (eof-object)
              (let ((chunk (car chunks)))
                (set! chunks (cdr chunks))
                (note (list 'read chunk))
                chunk)))))
  (cli-repl-run
   read-chunk
   (lambda (record)
     (when (and (eq? (kind record) 'repl-prompt)
                (eq? (field record 'state) 'continuation))
       (note 'continuation-prompt)))
   (lambda (output) output)
   "repl-main")
  ;; The first chunk is read, then the gutter is emitted, then the continued
  ;; line is read: the prompt fronts the second line rather than trailing it.
  (check 'continuation-prompt-precedes-read
         (reverse events)
         (list (list 'read "(+ 1\n")
               'continuation-prompt
               (list 'read "2)\n"))))

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
    (check 'explicit-exit-count
           (consent-number-value (field exit 'count)) 2)))

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

;;;; Pluggable chrome layer (presentation over the canonical record stream)

;; The ANSI SGR escape, built without a literal escape character in source.
(define escape (string (integer->char 27)))

;; Return #t when HAYSTACK contains NEEDLE as a substring.
(define (string-contains? haystack needle)
  (let ((hay (string-length haystack))
        (need (string-length needle)))
    (if (zero? need)
        #t
        (let loop ((start 0))
          (cond
           ((> (+ start need) hay) #f)
           ((let match ((index 0))
              (cond
               ((>= index need) #t)
               ((char=? (string-ref haystack (+ start index))
                        (string-ref needle index))
                (match (+ index 1)))
               (else #f)))
            #t)
           (else (loop (+ start 1))))))))

;;;; Model transport diagnostics stay specific and structured

(let* ((input
        (string-append
         "(import (scheme base) (agent models))\n"
         "(model-provider-register!\n"
         " '(model-provider\n"
         "   (id local-fail)\n"
         "   (kind local)\n"
         "   (transport openai-compatible-http)\n"
         "   (endpoint \"http://127.0.0.1:1/v1\")\n"
         "   (models\n"
         "    (((id qwen-coder)\n"
         "      (roles (scheme-scripter))\n"
         "      (privacy local))))))\n"
         "(model-complete 'scheme-scripter\n"
         "                \"transport diagnostic prompt\"\n"
         "                '((timeout-seconds 1)\n"
         "                  (retry-count 0)\n"
         "                  (max-transport-detail-bytes 320)))\n"))
       (records (drive input))
       (condition-record (car (records-of records 'repl-condition)))
       (condition (field condition-record 'condition))
       (irritants (field condition 'irritants))
       (detail (and (pair? irritants) (car irritants)))
       (request (and detail (field detail 'request)))
       (process (and detail (field detail 'process)))
       (comment-rendered
        (cli-repl-chrome-paint
         ((cli-repl-chrome-lookup 'comment) condition-record)
         #f)))
  (check 'model-transport-condition-phase
         (field condition-record 'phase) 'eval)
  (check 'model-transport-condition-type
         (field condition 'type) 'evaluation-error)
  (check-true 'model-transport-display-specific
              (string-contains? (field condition-record 'display)
                                "local model transport failed"))
  (check-true 'model-transport-display-provider
              (string-contains? (field condition-record 'display)
                                "local-fail"))
  (check-true 'model-transport-comment-specific
              (string-contains? comment-rendered
                                "local model transport failed"))
  (check 'model-transport-detail-head
         (and (pair? detail) (car detail))
         'model-provider-error)
  (check 'model-transport-detail-provider
         (field detail 'provider) 'local-fail)
  (check 'model-transport-detail-model
         (field detail 'model) 'qwen-coder)
  (check 'model-transport-detail-transport
         (field detail 'transport) 'openai-compatible-http)
  (check 'model-transport-process-head
         (and (pair? process) (car process))
         'process-failure)
  (check-true 'model-transport-process-detail-bounded
              (let ((detail-text (field process 'detail)))
                (and (string? detail-text)
                     (> (string-length detail-text) 0)
                     (<= (string-length detail-text) 240))))
  (check-false 'model-transport-process-detail-not-generic
               (string-contains? (field process 'detail)
                                 "no process detail"))
  (check-true 'model-transport-detail-budget-recorded
              (string-contains? (consent-datum->external detail)
                                "(max-transport-detail-bytes"))
  (check-true 'model-transport-detail-request-path
              (string-contains? (consent-datum->external detail)
                                "/v1/chat/completions"))
  (check-false 'model-transport-detail-no-prompt
               (string-contains? (consent-datum->external detail)
                                 "transport diagnostic prompt")))

;; Render RECORDS as the raw datum stream the `datum' chrome must reproduce.
(define (datum-stream records)
  (let ((port (open-output-string)))
    (for-each (lambda (record)
                (write-string (consent-datum->external record) port)
                (newline port))
              records)
    (get-output-string port)))

;; Return the ordered `display' strings of the `repl-result' records in RECORDS.
(define (result-displays records)
  (map (lambda (result) (field result 'display))
       (records-of records 'repl-result)))

;;;; The registry: built-in chromes are ordinary registered procedures

(check 'chrome-default-name (cli-repl-chrome-default-name) 'comment)
(check-true 'chrome-comment-procedure
            (procedure? (cli-repl-chrome-lookup 'comment)))
(check-true 'chrome-lookup-by-string
            (procedure? (cli-repl-chrome-lookup "classic")))
(check-false 'chrome-unknown-lookup (cli-repl-chrome-lookup 'no-such-chrome))
(let ((names (cli-repl-chrome-names)))
  (check-true 'chrome-names-complete
              (and (memq 'comment names) (memq 'datum names)
                   (memq 'classic names) (memq 'quiet names)
                   (memq 'silent names) #t)))

;;;; The `datum' chrome reproduces the raw record stream and stays reachable

;; Paint each record with the datum chrome over the SAME record objects the raw
;; stream writes, so the comparison is stable on hosts whose `write' embeds a
;; per-object address for opaque values.
(let* ((records (drive "(+ 1 2)\n(exit)\n"))
       (datum (cli-repl-chrome-lookup 'datum))
       (render (lambda (color?)
                 (let loop ((records records) (accumulated ""))
                   (if (null? records)
                       accumulated
                       (loop (cdr records)
                             (string-append
                              accumulated
                              (cli-repl-chrome-paint (datum (car records))
                                                     color?))))))))
  (check 'datum-recovers-raw-stream (render #f) (datum-stream records))
  ;; The datum chrome is never colored, even with color forced on.
  (check-false 'datum-never-colored (string-contains? (render #t) escape))
  ;; The canonical view is reachable regardless of any default chrome change.
  (check-true 'datum-always-reachable
              (procedure? (cli-repl-chrome-lookup 'datum))))

;;;; The `comment' chrome is valid, replayable Consent Scheme

(let* ((input "(+ 1 2)\n(define base 7)\n(* base 3)\n")
       (rendered (cli-repl-rendered-from-string input "repl-main" 'comment #f)))
  ;; Prompts, results, and diagnostics are block comments.
  (check-true 'comment-uses-block-comments (string-contains? rendered "#| "))
  ;; Re-driving the rendered control stream reproduces the same results: the
  ;; comments are ignored and the echoed forms re-evaluate identically.
  (check 'comment-replays-unedited
         (result-displays (drive rendered))
         (result-displays (drive input))))

;; On an interactive TTY the terminal already echoes each typed form, so the
;; comment chrome suppresses its own submission echo: the captured transcript
;; then holds exactly one copy of each form and replays once, not twice.  The
;; string-driven hook models that input-echoed posture with its optional flag.
(let* ((input "(+ 1 2)\n(define base 7)\n(set! base 9)\n(* base 3)\n")
       (echoed (cli-repl-rendered-from-string input "repl-main" 'comment #f #t))
       (piped (cli-repl-rendered-from-string input "repl-main" 'comment #f)))
  ;; The piped render carries one bare echo per form (the chrome's single copy);
  ;; the interactive render carries none, since the terminal supplies that copy.
  (check 'comment-echoed-suppresses-submission-echo
         (result-displays (drive echoed))
         '())
  (check-true 'comment-piped-still-echoes
              (> (length (result-displays (drive piped))) 0))
  ;; Prompts, results, and diagnostics are still rendered as line comments;
  ;; only the redundant submission echo is dropped.
  (check-true 'comment-echoed-keeps-result-comments
              (string-contains? echoed ";;   => "))
  ;; The single replayable copy lives in the terminal echo (the input itself);
  ;; replaying input + the echo-suppressed chrome evaluates each form exactly
  ;; once, matching the original session.
  (check 'comment-echoed-replays-once
         (result-displays (drive input))
         (result-displays (drive (string-append input echoed)))))

;; The default-session prompt shows the ordinal alone; the result is its own
;; `;;'-aligned line comment followed by a `;;' separator, and the EOF exit is a
;; `;;   __ ' line aligned from the close count.
(check 'comment-default-session-prompt
       (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'comment #f)
       "#| 1 |# (+ 1 2)\n;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n")
;; Under the input-echoed posture the same session drops the bare submission
;; echo: the terminal's own echo lands in that exact slot after the prompt.
(check 'comment-echoed-default-session-prompt
       (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'comment #f #t)
       "#| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n")
;; A blank line at an input-echoed ready prompt does not start a submission and
;; does not mean continuation.  The control-channel helper shows adjacent
;; same-ordinal prompts; in a live TTY the echoed blank line sits between them.
(check 'comment-echoed-blank-ready-reprompts
       (cli-repl-rendered-from-string "\n(+ 1 2)\n" "repl-main" 'comment #f #t)
       "#| 1 |# #| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n")
;; A named session grows a `<session>:<ordinal>' body, and the markers align to
;; that wider gutter so the value still lands under the echoed form.
(check 'comment-named-session-prompt
       (cli-repl-rendered-from-string "(+ 1 2)\n" "project-main" 'comment #f)
       (string-append
        "#| project-main:1 |# (+ 1 2)\n;;                => 3\n;;\n"
        "#| project-main:2 |# ;;                __ exit closed-ok\n"))
;; Marker alignment tracks the ordinal width: a 1-digit ordinal gives `;;   => '
;; (3 pad) and a 2-digit ordinal `;;    => ' (4 pad), with the continuation dots
;; widening to match.
(check 'comment-two-digit-ordinal-alignment
       (cli-repl-rendered-from-string
        "1\n2\n3\n4\n5\n6\n7\n8\n9\n(+ 1 1)\n" "repl-main" 'comment #f)
       (string-append
        "#| 1 |# 1\n;;   => 1\n;;\n#| 2 |# 2\n;;   => 2\n;;\n"
        "#| 3 |# 3\n;;   => 3\n;;\n#| 4 |# 4\n;;   => 4\n;;\n"
        "#| 5 |# 5\n;;   => 5\n;;\n#| 6 |# 6\n;;   => 6\n;;\n"
        "#| 7 |# 7\n;;   => 7\n;;\n#| 8 |# 8\n;;   => 8\n;;\n"
        "#| 9 |# 9\n;;   => 9\n;;\n#| 10 |# (+ 1 1)\n;;    => 2\n;;\n"
        "#| 11 |# ;;    __ exit closed-ok\n"))

;;;; The `classic', `quiet', and `silent' chromes

;; `classic' echoes the whole form after `> ', marks the value with `= ', and
;; closes with a `_ ' exit line; a blank line separates turns.
(check 'classic-prompts-and-values
       (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'classic #f)
       "> (+ 1 2)\n= 3\n\n> _ exit closed-ok\n")
;; The same blank-ready-prompt redraw applies to `classic'.  The helper omits
;; terminal echo, so it shows the repeated ready prompts next to each other.
(check 'classic-echoed-blank-ready-reprompts
       (cli-repl-rendered-from-string "\n(+ 1 2)\n" "repl-main" 'classic #f #t)
       "> > = 3\n\n> _ exit closed-ok\n")
;; A condition is marked `! ' (not `- '), so it pops in a colorless capture.  The
;; diagnostic text is now cross-host identical for an error whose wording agrees
;; (the `consent eval error: ' prefix matches the Emacs twin after its message
;; convergence), so assert the whole line exactly.
(check 'classic-condition-marker
       (cli-repl-rendered-from-string "(/ 1 0)\n" "repl-main" 'classic #f)
       (string-append "> (/ 1 0)\n! consent eval error: / division by zero"
                      "\n\n> _ exit closed-ok\n"))
;; `> ' and `. ' are both two columns, so a continued form's code aligns with
;; the first submission's code; the open-construct count is dropped.
(check 'classic-continuation-aligns
       (cli-repl-rendered-from-string "(+ 1\n2)\n" "repl-main" 'classic #f)
       "> . (+ 1\n2)\n= 3\n\n> _ exit closed-ok\n")
;; A deeper continuation just adds another `. ' gutter -- no nesting count.
(check 'classic-continuation-no-count
       (cli-repl-rendered-from-string "(+ (* 2\n3)\n4)\n" "repl-main"
                                      'classic #f)
       "> . . (+ (* 2\n3)\n4)\n= 10\n\n> _ exit closed-ok\n")
;; The comment chrome's continuation gutter is width-matched alignment dots
;; (one dot per ordinal digit), with no nesting count.
(check-true 'comment-continuation-dots
            (string-contains?
             (cli-repl-rendered-from-string "(+ (* 2\n3)\n4)\n" "repl-main"
                                            'comment #f)
             "#| . |# "))
(check 'quiet-results-only
       (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'quiet #f)
       "3\n")
(check 'silent-suppresses-all
       (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'silent #f)
       "")

;;;; A recoverable condition still renders under a human chrome

(let ((rendered
       (cli-repl-rendered-from-string "undefined-name\n" "repl-main"
                                      'comment #f)))
  (check-true 'comment-condition-marker (string-contains? rendered ";;   !! ")))

;;;; Program output: `comment' owns it (control channel), others keep it raw

;; Every R7RS host's display/newline needs the write/base bindings; importing
;; them first makes the program-output cases deterministic across hosts.
(define output-prelude "(import (scheme base) (scheme write))\n")

;; `comment' renders each printed line as a `;;   :: ' comment aligned to the
;; result marker, on the control channel, so the whole transcript -- program
;; output included -- is line comments and bare source.
(check 'comment-output-on-control-channel
       (cli-repl-rendered-from-string
        (string-append output-prelude "(display \"hi\\n\")\n(+ 1 1)\n")
        "repl-main" 'comment #f)
       (string-append
        "#| 1 |# (import (scheme base) (scheme write))\n;;   => (unspecified)\n;;\n"
        "#| 2 |# (display \"hi\\n\")\n;;   :: hi\n;;   => (unspecified)\n;;\n"
        "#| 3 |# (+ 1 1)\n;;   => 2\n;;\n#| 4 |# ;;   __ exit closed-ok\n"))
;; Because `comment' owns program output, stdout (the program-output stream)
;; carries nothing under it.
(check 'comment-output-leaves-stdout-clean
       (cdr (cli-repl-capture-from-string
             (string-append output-prelude "(display \"hi\\n\")\n(+ 1 1)\n")
             "repl-main" 'comment #f))
       "")
;; Multi-line output is one `;;   :: ' comment per line.
(check-true 'comment-output-multi-line
            (string-contains?
             (cli-repl-rendered-from-string
              (string-append output-prelude
                             "(begin (display \"a\")(newline)(display \"b\")"
                             "(newline) 0)\n")
              "repl-main" 'comment #f)
             ";;   :: a\n;;   :: b\n;;   => 0"))
;; Output that ends without a newline still gets a terminating one so the comment
;; closes before the result line.
(check-true 'comment-output-no-trailing-newline
            (string-contains?
             (cli-repl-rendered-from-string
              (string-append output-prelude "(begin (display \"x\") 5)\n")
              "repl-main" 'comment #f)
             ";;   :: x\n;;   => 5"))
;; `classic' (and every non-`comment' chrome) leaves program output raw on its
;; own stream; the control channel carries records only, not the printed text.
;; The printed value (12321) is computed so it is absent from the echoed source.
(let ((classic (cli-repl-capture-from-string
                (string-append output-prelude
                               "(begin (display (* 111 111))(newline) 1)\n")
                "repl-main" 'classic #f)))
  (check 'classic-output-raw-on-stdout (cdr classic) "12321\n")
  (check-false 'classic-output-not-on-control-channel
               (string-contains? (car classic) "12321")))
;; The `comment' control-channel transcript round-trips through a fresh session:
;; the commented output is inert on replay and the re-evaluated forms regenerate
;; it, so the per-submission results match the original input's.
(let* ((input (string-append output-prelude
                             "(display \"hello\\n\")\n"
                             "(begin (display \"x\")(newline) 42)\n"
                             "(+ 2 3)\n"))
       (transcript (cli-repl-rendered-from-string input "repl-main" 'comment #f)))
  (check 'comment-output-transcript-replays
         (result-displays (drive transcript))
         (result-displays (drive input))))

;;;; Color is TTY-gated, overridable, and strips when piped or NO_COLOR is set

(check 'color-never-off (cli-repl-chrome-color? 'never #f #t) #f)
(check 'color-always-on (cli-repl-chrome-color? 'always #t #f) #t)
(check 'color-auto-tty-on (cli-repl-chrome-color? 'auto #f #t) #t)
(check 'color-auto-piped-off (cli-repl-chrome-color? 'auto #f #f) #f)
(check 'color-auto-no-color-off (cli-repl-chrome-color? 'auto #t #t) #f)

;; The painter adds ANSI SGR only when color is enabled.
(check-true 'paint-color-emits-escape
            (string-contains?
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'comment #t)
             escape))
(check-false 'paint-plain-has-no-escape
             (string-contains?
              (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main"
                                             'comment #f)
              escape))

;;;; Option parsing: --session, --chrome, --color (inline and spaced)

(let ((options (cli-repl-parse-options
                (list "--chrome" "classic" "--color=always" "--session" "demo"))))
  (check 'parse-session (cdr (assq 'session options)) "demo")
  (check 'parse-chrome (cdr (assq 'chrome options)) 'classic)
  (check 'parse-color-inline (cdr (assq 'color options)) 'always))
(let ((options (cli-repl-parse-options (list "--color" "never"))))
  (check 'parse-color-spaced (cdr (assq 'color options)) 'never)
  (check 'parse-chrome-default (cdr (assq 'chrome options)) 'comment)
  (check 'parse-session-default (cdr (assq 'session options)) "repl-main"))
;; A bare `--repl' token (passed through from the compiled host dispatch) and any
;; unrecognized argument are ignored, leaving the defaults intact.
(let ((options (cli-repl-parse-options (list "--repl"))))
  (check 'parse-ignores-repl-token (cdr (assq 'chrome options)) 'comment))
;; `--replay FILE' carries the transcript path; the default is #f (stdin session).
(check 'parse-replay
       (cdr (assq 'replay (cli-repl-parse-options (list "--replay" "t.scm"))))
       "t.scm")
(check 'parse-replay-default
       (cdr (assq 'replay (cli-repl-parse-options '())))
       #f)

;;;; Transcript capture and replay (docs/repl-interaction-contract.md)

;; Serialize a record stream through the consent writer -- the canonical capture
;; form.  Comparing serialized streams is host-portable: value-equal canonical
;; numbers render identically, so two streams serialize the same exactly when
;; they carry the same data, sidestepping per-host record identity.
(define (serialize records)
  (map consent-datum->external records))

;; A captured transcript, serialized to the datum stream, reloads with the
;; standard reader (plain data) and carries exactly the complete submissions a
;; replay re-feeds, so the saved-file round-trip replays to the same stream.
(let* ((captured (drive "(define base 7)\n(* base 3)\n"))
       (text (apply string-append
                    (map (lambda (r)
                           (string-append (consent-datum->external r) "\n"))
                         captured)))
       (reloaded (cli-repl-records-from-datum-stream text)))
  (check 'reload-record-count (length reloaded) (length captured))
  (check 'reload-extracts-submissions
         (cli-repl-submissions-from-records reloaded)
         '("(define base 7)" "(* base 3)"))
  ;; Replaying the reloaded transcript reproduces the captured record stream.
  (check 'reload-replays-equal
         (serialize (cli-repl-replay-records reloaded "project-main"))
         (serialize captured)))

;; An EOF-truncated partial form is not a complete submission, so it contributes
;; no replayable source.
(check 'submissions-skip-incomplete
       (cli-repl-submissions-from-records (drive "(+ 1\n"))
       '())

;; A pure transcript replays to an EQUAL record stream, and the report says so.
(let* ((captured (drive "(import (scheme base))\n(define base 20)\n(* base 3)\n"))
       (replayed (cli-repl-replay-records captured "project-main"))
       (report (cli-repl-replay-report captured replayed)))
  (check 'replay-input
         (cli-repl-replay-input captured)
         "(import (scheme base))\n(define base 20)\n(* base 3)\n")
  (check 'replay-pure-roundtrip (serialize replayed) (serialize captured))
  (check 'replay-report-reproduced (field report 'status) 'reproduced)
  (check 'replay-report-no-divergences (field report 'divergences) '())
  (check 'replay-report-submission-count
         (consent-number-value (field report 'submissions)) 3))

;; A live host effect cannot be reproduced under a weaker replay posture.  A
;; submission that resolved the session interaction environment as a result when
;; captured fails closed as a condition when replayed under a denying posture;
;; the report records that divergence rather than letting it pass silently
;; (docs "Capture and Replay": effectful forms fail closed, not silently).
(let* ((captured (drive (string-append
                         "(import (scheme base) (scheme repl))\n"
                         "(interaction-environment)\n")))
       (replayed (cli-repl-replay-records
                  captured "project-main"
                  '((policy-actions (standard-host-effect . deny)))))
       (report (cli-repl-replay-report captured replayed)))
  ;; Capture: both forms succeeded (two results, no conditions).
  (check 'replay-effect-captured-results (count-of captured 'repl-result) 2)
  (check 'replay-effect-captured-no-conditions
         (count-of captured 'repl-condition) 0)
  ;; Replay denied the effect: the interaction-environment form is a condition.
  (check 'replay-effect-replayed-results (count-of replayed 'repl-result) 1)
  (check 'replay-effect-replayed-conditions (count-of replayed 'repl-condition) 1)
  ;; The report flags the result -> condition divergence with its source.
  (check 'replay-report-status-diverged (field report 'status) 'diverged)
  (let ((divergence (car (field report 'divergences))))
    (check 'replay-divergence-source
           (field divergence 'source) "(interaction-environment)")
    (check 'replay-divergence-captured-kind
           (field (assq 'captured (cdr divergence)) 'kind) 'result)
    (check 'replay-divergence-replayed-kind
           (field (assq 'replayed (cdr divergence)) 'kind) 'condition)))

(if (> failures 0)
    (error "portable terminal REPL tests failed" failures))
