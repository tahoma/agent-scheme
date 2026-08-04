;;; Portable terminal REPL shell tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; terminal REPL shell (cli repl-shell) against the cross-host REPL
;;; interaction
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
        (cli repl-chrome)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Contract records leave the evaluator through its native result boundary, so
;; this host-side consumer sees ordinary Scheme symbols throughout.

(define (test-symbol-equal name expected actual)
  "Assert that EXPECTED and ACTUAL are the same host symbol."
  (test-assert name
               (and (symbol? actual)
                    (eq? expected actual))))

;; Normalize a numeric literal across direct hosts and self-hosted runners.
(define (portable-host-number datum)
  (consent-number-value datum))

;;;; Record helpers

;; Return the single value of field NAME in tagged list DATUM, or #f.
(define (field datum name)
  (let loop ((fields (if (pair? datum) (cdr datum) '())))
    (cond
     ((null? fields) #f)
     ((and (pair? (car fields))
           (eq? (caar fields) name)
           (pair? (cdar fields)))
      (car (cdar fields)))
     (else (loop (cdr fields))))))

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

(testing-registry-case
 'simple-eval-display '(portable core)
(let ((records (drive "(+ 1 2)\n")))
  (let ((result (car (records-of records 'repl-result))))
    (test-equal 'simple-eval-display "3" (field result 'display))
    (test-equal 'simple-eval-submission 'sub-1 (field result 'submission))
    (let ((evaluation (field result 'evaluation-result)))
      (test-assert 'simple-eval-wraps-evaluation-result
             (and (pair? evaluation)
                       (eq? (car evaluation) 'evaluation-result)))
      (test-equal 'simple-eval-status 'ok (field evaluation 'status))))
  ;; The first prompt is a ready primary prompt; exactly one exit closes
  ;; cleanly.
  (let ((prompt (car (records-of records 'repl-prompt))))
    (test-equal 'simple-eval-prompt-state 'ready (field prompt 'state))
    (test-equal 'simple-eval-prompt-pending #f (field prompt 'pending))
    (test-equal 'simple-eval-prompt-ordinal
             (portable-host-number 1)
             (consent-number-value (field prompt 'ordinal))))
  (test-equal 'simple-eval-one-exit 1 (count-of records 'repl-exit))
  (let ((exit (car (records-of records 'repl-exit))))
    (test-equal 'simple-eval-exit-reason 'eof (field exit 'reason))
    (test-equal 'simple-eval-exit-status 'closed-ok (field exit 'status))
    (test-equal 'simple-eval-exit-count
             (portable-host-number 1)
             (consent-number-value (field exit 'count))))))

;;;; Definitions, imports, and macros persist across submissions

(testing-registry-case
 'persist-result-count '(portable core)
(let ((records
       (drive
        (string-append
         "(import (scheme base))\n"
         "(define base 20)\n"
         "(define-syntax inc (syntax-rules () ((_ v) (+ v 1))))\n"
         "(inc base)\n"))))
  (let ((results (records-of records 'repl-result)))
    (test-equal 'persist-result-count 4 (length results))
    ;; The fourth submission uses the macro and the earlier definition.
    (test-equal 'persist-macro-and-definition
             "21"
             (field (list-ref results 3) 'display)))
  (test-equal 'persist-no-conditions 0 (count-of records 'repl-condition))))

;;;; Session-gated interaction-environment resolves inside the session

(testing-registry-case
 'interaction-environment-value '(portable core)
(let ((records
       (drive
        (string-append
         "(import (scheme base) (scheme eval) (scheme repl))\n"
         "(eval (quote (define made 5)) (interaction-environment))\n"
         "made\n"))))
  (let ((results (records-of records 'repl-result)))
    (test-equal 'interaction-environment-value
             "5"
             (field (list-ref results 2) 'display)))
  (test-equal 'interaction-environment-no-conditions
             0
             (count-of records 'repl-condition))))

;;;; A recoverable evaluator condition keeps the session open

(testing-registry-case
 'eval-condition-phase '(portable core)
(let ((records (drive "undefined-name\n(+ 4 5)\n")))
  (let ((condition (car (records-of records 'repl-condition))))
    (test-equal 'eval-condition-phase 'eval (field condition 'phase))
    (test-equal 'eval-condition-recoverable #t (field condition 'recoverable))
    (test-equal 'eval-condition-submission 'sub-1 (field condition
      'submission)))
  ;; The session keeps running: the following form still evaluates.
  (let ((result (car (records-of records 'repl-result))))
    (test-equal 'eval-condition-session-continues "9" (field result 'display)))
  (test-equal 'eval-condition-clean-close
             'closed-ok
             (field (car (records-of records 'repl-exit)) 'status))))

(testing-registry-case
 'unbound-identifier-display-names-symbol '(portable core)
(let ((records (drive (string-append
                       "(define (uses-missing-helper value)\n"
                       "  (missing-helper value))\n"
                       "(uses-missing-helper '(a b))\n"))))
  (let* ((condition-record (car (records-of records 'repl-condition)))
         (condition (field condition-record 'condition)))
    (test-equal 'unbound-identifier-display-names-symbol
             "consent eval error: unbound identifier: missing-helper"
             (field condition-record 'display))
    (test-symbol-equal 'unbound-identifier-condition-symbol
                       'missing-helper
                       (field condition 'symbol)))))

;;;; A recoverable reader condition keeps the session open

(testing-registry-case
 'read-condition-phase '(portable core)
(let ((records (drive ")\n(+ 6 7)\n")))
  (let ((condition (car (records-of records 'repl-condition))))
    (test-equal 'read-condition-phase 'read (field condition 'phase))
    (test-equal 'read-condition-recoverable #t (field condition 'recoverable)))
  (let ((result (car (records-of records 'repl-result))))
    (test-equal 'read-condition-session-continues "13" (field result
      'display)))))

;;;; An incomplete form is continued, not reported as a hard error

(testing-registry-case
 'continuation-second-prompt-state '(portable core)
(let ((records (drive "(+ 1\n2)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (test-equal 'continuation-second-prompt-state
             'continuation
             (field (list-ref prompts 1) 'state))
    (test-equal 'continuation-second-prompt-pending
             #t
             (field (list-ref prompts 1) 'pending))
    (test-equal 'continuation-keeps-ordinal
             (portable-host-number 1)
             (consent-number-value (field (list-ref prompts 1) 'ordinal))))
  (let ((submission (car (records-of records 'repl-submission))))
    (test-equal 'continuation-submission-complete #t (field submission
      'complete))
    (test-equal 'continuation-submission-source "(+ 1\n2)" (field submission
      'source)))
  (test-equal 'continuation-result
             "3"
             (field (car (records-of records 'repl-result))
                                     'display))))

;;;; Blank ready-prompt input redraws a same-ordinal ready prompt

(testing-registry-case
 'blank-ready-prompt-count '(portable core)
(let ((records (drive "\n(+ 1 2)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (test-equal 'blank-ready-prompt-count 3 (length prompts))
    (test-equal 'blank-ready-first-state 'ready (field (list-ref prompts 0)
      'state))
    (test-equal 'blank-ready-second-state 'ready (field (list-ref prompts 1)
      'state))
    (test-equal 'blank-ready-third-state 'ready (field (list-ref prompts 2)
      'state))
    (test-equal 'blank-ready-first-ordinal
             (portable-host-number 1)
             (consent-number-value (field (list-ref prompts 0) 'ordinal)))
    (test-equal 'blank-ready-second-ordinal
             (portable-host-number 1)
             (consent-number-value (field (list-ref prompts 1) 'ordinal)))
    (test-equal 'blank-ready-third-ordinal
             (portable-host-number 2)
             (consent-number-value (field (list-ref prompts 2) 'ordinal))))
  (test-equal 'blank-ready-submission-count
             1
             (count-of records 'repl-submission))
  (test-equal 'blank-ready-result
             "3"
             (field (car (records-of records 'repl-result)) 'display))))

(testing-registry-case
 'line-comment-ready-prompt-count '(portable core)
(let ((records (drive "  ;; comment\n(+ 1 2)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (test-equal 'line-comment-ready-prompt-count 3 (length prompts))
    (test-equal 'line-comment-ready-first-state
             'ready
             (field (list-ref prompts 0) 'state))
    (test-equal 'line-comment-ready-second-state
             'ready
             (field (list-ref prompts 1) 'state))
    (test-equal 'line-comment-ready-third-state
             'ready
             (field (list-ref prompts 2) 'state))
    (test-equal 'line-comment-ready-first-ordinal
             (portable-host-number 1)
             (consent-number-value (field (list-ref prompts 0) 'ordinal)))
    (test-equal 'line-comment-ready-second-ordinal
             (portable-host-number 1)
             (consent-number-value (field (list-ref prompts 1) 'ordinal)))
    (test-equal 'line-comment-ready-third-ordinal
             (portable-host-number 2)
             (consent-number-value (field (list-ref prompts 2) 'ordinal))))
  (test-equal 'line-comment-ready-submission-count
             1
             (count-of records 'repl-submission))
  (test-equal 'line-comment-ready-submission-source
             "(+ 1 2)"
             (field (car (records-of records 'repl-submission)) 'source))
  (test-equal 'line-comment-ready-result
             "3"
             (field (car (records-of records 'repl-result)) 'display))))

;;;; The continuation prompt carries the reader's pending-nesting indicator

;; The depth narrows as constructs close (two open lists, then one), the kind
;; names the innermost pending construct, and a ready prompt omits both fields.
(testing-registry-case
 'nesting-ready-prompt-omits-field '(portable core)
(let ((records (drive "(+ (* 2\n3)\n4)\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (test-equal 'nesting-ready-prompt-omits-field
             #f
             (field (list-ref prompts 0) 'nesting))
    (test-equal 'nesting-depth-two
             (portable-host-number 2)
             (consent-number-value (field (list-ref prompts 1) 'nesting)))
    (test-equal 'nesting-kind-list
             'list
             (field (list-ref prompts 1) 'pending-kind))
    (test-equal 'nesting-narrows-to-one
             (portable-host-number 1)
             (consent-number-value (field (list-ref prompts 2) 'nesting))))))

;; An unterminated string is the innermost pending construct even inside a
;; list, so a chrome can distinguish "inside a string" from list nesting.
(testing-registry-case
 'nesting-string-depth '(portable core)
(let ((records (drive "(string-length \"a\nb\")\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (test-equal 'nesting-string-depth
             (portable-host-number 2)
             (consent-number-value (field (list-ref prompts 1) 'nesting)))
    (test-equal 'nesting-string-kind
             'string
             (field (list-ref prompts 1) 'pending-kind)))))

;; A pending datum prefix (a lone quote) keeps the session continuing with an
;; empty construct stack: depth zero and the `datum' pending kind.
(testing-registry-case
 'nesting-datum-prefix-depth '(portable core)
(let ((records (drive "'\n1\n")))
  (let ((prompts (records-of records 'repl-prompt)))
    (test-equal 'nesting-datum-prefix-depth
             (portable-host-number 0)
             (consent-number-value (field (list-ref prompts 1) 'nesting)))
    (test-equal 'nesting-datum-prefix-kind
             'datum
             (field (list-ref prompts 1) 'pending-kind)))
  (test-equal 'nesting-datum-prefix-result
             "1"
             (field (car (records-of records 'repl-result)) 'display))))

;;;; The continuation prompt is emitted before the read it requests

;; A continuation gutter is a request for more input, so it must be emitted
;; (and
;; flushed) *before* the blocking read that supplies the continued line -- on a
;; live TTY a prompt emitted after the read would land glued to the next result
;; line instead of fronting the continued input.  The record-stream order alone
;; cannot capture this: a fully-buffered string never blocks, so the emission
;; order of records is identical either way.  Instrument the read/emit
;; interleaving directly -- log each chunk read alongside the continuation
;; prompt
;; -- and assert exactly one chunk is read before the prompt is emitted.
(testing-registry-case
 'continuation-prompt-precedes-read '(portable core)
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
  (test-equal 'continuation-prompt-precedes-read
             (list (list 'read "(+ 1\n")
               'continuation-prompt
               (list 'read "2)\n"))
             (reverse events))))

;;;; EOF mid-form closes with the documented error status

(testing-registry-case
 'eof-incomplete-submission-complete '(portable core)
(let ((records (drive "(+ 1\n")))
  (let ((submission (car (records-of records 'repl-submission))))
    (test-equal 'eof-incomplete-submission-complete #f (field submission
      'complete))
    (test-equal 'eof-incomplete-submission-eof #t (field submission 'eof)))
  (let ((condition (car (records-of records 'repl-condition))))
    (test-equal 'eof-incomplete-condition-phase 'read (field condition 'phase))
    (test-equal 'eof-incomplete-condition-unrecoverable
             #f
             (field condition 'recoverable)))
  (let ((exit (car (records-of records 'repl-exit))))
    (test-equal 'eof-incomplete-exit-reason 'eof (field exit 'reason))
    (test-equal 'eof-incomplete-exit-status 'closed-error (field exit
      'status)))))

;;;; Explicit exit closes with the explicit reason and clean status

(testing-registry-case
 'explicit-exit-one-exit '(portable core)
(let ((records (drive "(+ 1 2)\n(exit)\n")))
  (test-equal 'explicit-exit-one-exit 1 (count-of records 'repl-exit))
  (let ((exit (car (records-of records 'repl-exit))))
    (test-equal 'explicit-exit-reason 'explicit (field exit 'reason))
    (test-equal 'explicit-exit-status 'closed-ok (field exit 'status))
    (test-equal 'explicit-exit-count
             (portable-host-number 2)
             (consent-number-value (field exit 'count))))))

;;;; Default policy denies an ungranted host effect, fail closed

(testing-registry-case
 'policy-denied-phase '(portable core)
(let ((records
       (drive
        "(begin (import (scheme file)) (open-output-file \"/tmp/consent-repl-d\
enied\"))\n")))
  (let ((condition (car (records-of records 'repl-condition))))
    (test-equal 'policy-denied-phase 'eval (field condition 'phase))
    (test-equal 'policy-denied-recoverable #t (field condition 'recoverable))
    (let ((datum (field condition 'condition)))
      (test-equal 'policy-denied-type 'policy-denial (field datum 'type))))
  ;; A denied effect does not crash the loop; the session still closes cleanly.
  (test-equal 'policy-denied-clean-close
             'closed-ok
             (field (car (records-of records 'repl-exit)) 'status))))

;;;; A session-policy denial of interaction-environment fails closed

(testing-registry-case
 'denied-interaction-environment-phase '(portable core)
(let ((records
       (drive
        (string-append
         "(import (scheme base) (scheme repl))\n"
         "(interaction-environment)\n")
        '((policy-actions . ((standard-host-effect . deny)))))))
  (let ((condition (car (records-of records 'repl-condition))))
    (test-equal 'denied-interaction-environment-phase 'eval (field condition
      'phase))
    (let ((datum (field condition 'condition)))
      (test-equal 'denied-interaction-environment-type
             'policy-denial
             (field datum 'type))))))

;;;; Program output is separated from the interaction record stream

(testing-registry-case
 'stream-separation-exit-code '(portable core)
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
    (test-equal 'stream-separation-exit-code 0 exit-code)
    ;; Program output reached the program-output stream...
    (test-equal 'stream-separation-program-output
             "emitted"
             (apply string-append (reverse output)))
    ;; ...and the record stream carries only contract records (one per
    ;; evaluated
    ;; submission: import, display, and the sum), never the program output
    ;; text.
    (let ((records (reverse records)))
      (test-equal 'stream-separation-result-count
             3
             (count-of records 'repl-result))
      (test-assert 'stream-separation-has-exit
             (> (count-of records 'repl-exit) 0))))))

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

(testing-registry-case
 'model-transport-condition-phase '(portable core)
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
  (test-equal 'model-transport-condition-phase
             'eval
             (field condition-record 'phase))
  (test-equal 'model-transport-condition-type
             'evaluation-error
             (field condition 'type))
  (test-assert 'model-transport-display-specific
             (string-contains? (field condition-record 'display)
                                "local model transport failed"))
  (test-assert 'model-transport-display-provider
             (string-contains? (field condition-record 'display)
                                "local-fail"))
  (test-assert 'model-transport-comment-specific
             (string-contains? comment-rendered
                                "local model transport failed"))
  (test-assert 'model-transport-comment-request-path
             (string-contains? comment-rendered
                                "/v1/chat/completions"))
  (test-equal 'model-transport-detail-head
             'model-provider-error
             (and (pair? detail) (car detail)))
  (test-symbol-equal 'model-transport-detail-provider
                     'local-fail
                     (field detail 'provider))
  (test-symbol-equal 'model-transport-detail-model
                     'qwen-coder
                     (field detail 'model))
  (test-symbol-equal 'model-transport-detail-transport
                     'openai-compatible-http
                     (field detail 'transport))
  (test-equal 'model-transport-process-head
             'process-failure
             (and (pair? process) (car process)))
  (test-assert 'model-transport-process-detail-bounded
             (let ((detail-text (field process 'detail)))
                (and (string? detail-text)
                     (> (string-length detail-text) 0)
                     (<= (string-length detail-text) 240))))
  (test-assert 'model-transport-process-detail-not-generic
             (not (string-contains? (field process 'detail)
                                 "no process detail")))
  (test-assert 'model-transport-detail-budget-recorded
             (string-contains? (consent-datum->external detail)
                                "(max-transport-detail-bytes"))
  (test-assert 'model-transport-detail-request-path
             (string-contains? (consent-datum->external detail)
                                "/v1/chat/completions"))
  (test-assert 'model-transport-detail-no-prompt
             (not (string-contains? (consent-datum->external detail)
                                 "transport diagnostic prompt")))))

;; Render RECORDS as the raw datum stream the `datum' chrome must reproduce.
(define (datum-stream records)
  (let ((port (open-output-string)))
    (for-each (lambda (record)
                (write-string (consent-datum->external record) port)
                (newline port))
              records)
    (get-output-string port)))

;; Return the ordered `display' strings of the `repl-result' records in
;; RECORDS.
(define (result-displays records)
  (map (lambda (result) (field result 'display))
       (records-of records 'repl-result)))

;;;; The registry: built-in chromes are ordinary registered procedures

(testing-registry-case
 'chrome-default-name '(portable core)
(test-equal 'chrome-default-name 'comment (cli-repl-chrome-default-name)))
(testing-registry-case
 'chrome-comment-procedure '(portable core)
(test-assert 'chrome-comment-procedure
             (procedure? (cli-repl-chrome-lookup 'comment))))
(testing-registry-case
 'chrome-lookup-by-string '(portable core)
(test-assert 'chrome-lookup-by-string
             (procedure? (cli-repl-chrome-lookup "classic"))))
(testing-registry-case
 'chrome-unknown-lookup '(portable core)
(test-assert 'chrome-unknown-lookup (not (cli-repl-chrome-lookup
  'no-such-chrome))))
(testing-registry-case
 'chrome-names-complete '(portable core)
(let ((names (cli-repl-chrome-names)))
  (test-assert 'chrome-names-complete
             (and (memq 'comment names) (memq 'datum names)
                   (memq 'classic names) (memq 'quiet names)
                   (memq 'silent names) #t))))

;;;; The `datum' chrome reproduces the raw record stream and stays reachable

;; Paint each record with the datum chrome over the SAME record objects the raw
;; stream writes, so the comparison is stable on hosts whose `write' embeds a
;; per-object address for opaque values.
(testing-registry-case
 'datum-recovers-raw-stream '(portable core)
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
  (test-equal 'datum-recovers-raw-stream (datum-stream records) (render #f))
  ;; The datum chrome is never colored, even with color forced on.
  (test-assert 'datum-never-colored (not (string-contains? (render #t)
    escape)))
  ;; The canonical view is reachable regardless of any default chrome change.
  (test-assert 'datum-always-reachable
             (procedure? (cli-repl-chrome-lookup 'datum)))))

;;;; The `comment' chrome is valid, replayable Consent Scheme

(testing-registry-case
 'comment-uses-block-comments '(portable core)
(let* ((input "(+ 1 2)\n(define base 7)\n(* base 3)\n")
       (rendered (cli-repl-rendered-from-string input "repl-main" 'comment
         #f)))
  ;; Prompts, results, and diagnostics are block comments.
  (test-assert 'comment-uses-block-comments (string-contains? rendered "#| "))
  ;; Re-driving the rendered control stream reproduces the same results: the
  ;; comments are ignored and the echoed forms re-evaluate identically.
  (test-equal 'comment-replays-unedited
             (result-displays (drive input))
             (result-displays (drive rendered)))))

;; On an interactive TTY the terminal already echoes each typed form, so the
;; comment chrome suppresses its own submission echo: the captured transcript
;; then holds exactly one copy of each form and replays once, not twice.  The
;; string-driven hook models that input-echoed posture with its optional flag.
(testing-registry-case
 'comment-echoed-suppresses-submission-echo '(portable core)
(let* ((input "(+ 1 2)\n(define base 7)\n(set! base 9)\n(* base 3)\n")
       (echoed (cli-repl-rendered-from-string input "repl-main" 'comment #f
         #t))
       (piped (cli-repl-rendered-from-string input "repl-main" 'comment #f)))
  ;; The piped render carries one bare echo per form (the chrome's single
  ;; copy);
  ;; the interactive render carries none, since the terminal supplies that
  ;; copy.
  (test-equal 'comment-echoed-suppresses-submission-echo
             '()
             (result-displays (drive echoed)))
  (test-assert 'comment-piped-still-echoes
             (> (length (result-displays (drive piped))) 0))
  ;; Prompts, results, and diagnostics are still rendered as line comments;
  ;; only the redundant submission echo is dropped.
  (test-assert 'comment-echoed-keeps-result-comments
             (string-contains? echoed ";;   => "))
  ;; The single replayable copy lives in the terminal echo (the input itself);
  ;; replaying input + the echo-suppressed chrome evaluates each form exactly
  ;; once, matching the original session.
  (test-equal 'comment-echoed-replays-once
             (result-displays (drive (string-append input echoed)))
             (result-displays (drive input)))))

;; The default-session prompt shows the ordinal alone; the result is its own
;; `;;'-aligned line comment followed by a `;;' separator, and the EOF exit is
;; a
;; `;;   __ ' line aligned from the close count.
(testing-registry-case
 'comment-default-session-prompt '(portable core)
(test-equal 'comment-default-session-prompt
             "#| 1 |# (+ 1 2)\n;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n\
"
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'comment
               #f)))
;; Under the input-echoed posture the same session drops the bare submission
;; echo: the terminal's own echo lands in that exact slot after the prompt.
(testing-registry-case
 'comment-echoed-default-session-prompt '(portable core)
(test-equal 'comment-echoed-default-session-prompt
             "#| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n"
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'comment #f
               #t)))
;; A blank line at an input-echoed ready prompt does not start a submission and
;; does not mean continuation.  The control-channel helper shows adjacent
;; same-ordinal prompts; in a live TTY the echoed blank line sits between them.
(testing-registry-case
 'comment-echoed-blank-ready-reprompts '(portable core)
(test-equal 'comment-echoed-blank-ready-reprompts
             "#| 1 |# #| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n"
             (cli-repl-rendered-from-string "\n(+ 1 2)\n" "repl-main" 'comment
               #f #t)))
(testing-registry-case
 'comment-echoed-line-comment-ready-reprompts '(portable core)
(test-equal 'comment-echoed-line-comment-ready-reprompts
             "#| 1 |# #| 1 |# ;;   => 3\n;;\n#| 2 |# ;;   __ exit closed-ok\n"
             (cli-repl-rendered-from-string
        "  ;; comment\n(+ 1 2)\n" "repl-main" 'comment #f #t)))
;; A named session grows a `<session>:<ordinal>' body, and the markers align to
;; that wider gutter so the value still lands under the echoed form.
(testing-registry-case
 'comment-named-session-prompt '(portable core)
(test-equal 'comment-named-session-prompt
             (string-append
        "#| project-main:1 |# (+ 1 2)\n;;                => 3\n;;\n"
        "#| project-main:2 |# ;;                __ exit closed-ok\n")
             (cli-repl-rendered-from-string "(+ 1 2)\n" "project-main" 'comment
               #f)))
;; Marker alignment tracks the ordinal width: a 1-digit ordinal gives `;; => '
;; (3 pad) and a 2-digit ordinal `;; => ' (4 pad), with the continuation dots
;; widening to match.
(testing-registry-case
 'comment-two-digit-ordinal-alignment '(portable core)
(test-equal 'comment-two-digit-ordinal-alignment
             (string-append
        "#| 1 |# 1\n;;   => 1\n;;\n#| 2 |# 2\n;;   => 2\n;;\n"
        "#| 3 |# 3\n;;   => 3\n;;\n#| 4 |# 4\n;;   => 4\n;;\n"
        "#| 5 |# 5\n;;   => 5\n;;\n#| 6 |# 6\n;;   => 6\n;;\n"
        "#| 7 |# 7\n;;   => 7\n;;\n#| 8 |# 8\n;;   => 8\n;;\n"
        "#| 9 |# 9\n;;   => 9\n;;\n#| 10 |# (+ 1 1)\n;;    => 2\n;;\n"
        "#| 11 |# ;;    __ exit closed-ok\n")
             (cli-repl-rendered-from-string
        "1\n2\n3\n4\n5\n6\n7\n8\n9\n(+ 1 1)\n" "repl-main" 'comment #f)))

;;;; The `classic', `quiet', and `silent' chromes

;; `classic' echoes the whole form after `> ', marks the value with `= ', and
;; closes with a `_ ' exit line; a blank line separates turns.
(testing-registry-case
 'classic-prompts-and-values '(portable core)
(test-equal 'classic-prompts-and-values
             "> (+ 1 2)\n= 3\n\n> _ exit closed-ok\n"
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'classic
               #f)))
;; The same blank-ready-prompt redraw applies to `classic'.  The helper omits
;; terminal echo, so it shows the repeated ready prompts next to each other.
(testing-registry-case
 'classic-echoed-blank-ready-reprompts '(portable core)
(test-equal 'classic-echoed-blank-ready-reprompts
             "> > = 3\n\n> _ exit closed-ok\n"
             (cli-repl-rendered-from-string "\n(+ 1 2)\n" "repl-main" 'classic
               #f #t)))
(testing-registry-case
 'classic-echoed-line-comment-ready-reprompts '(portable core)
(test-equal 'classic-echoed-line-comment-ready-reprompts
             "> > = 3\n\n> _ exit closed-ok\n"
             (cli-repl-rendered-from-string
        "  ;; comment\n(+ 1 2)\n" "repl-main" 'classic #f #t)))
;; A condition is marked `! ' (not `- '), so it pops in a colorless capture.
;; The
;; diagnostic text is now cross-host identical for an error whose wording
;; agrees
;; (the `consent eval error: ' prefix matches the Emacs twin after its message
;; convergence), so assert the whole line exactly.
(testing-registry-case
 'classic-condition-marker '(portable core)
(test-equal 'classic-condition-marker
             (string-append
               "> (/ 1 0)\n! consent eval error: / division by zero"
                      "\n\n> _ exit closed-ok\n")
             (cli-repl-rendered-from-string "(/ 1 0)\n" "repl-main" 'classic
               #f)))
;; `> ' and `. ' are both two columns, so a continued form's code aligns with
;; the first submission's code; the open-construct count is dropped.
(testing-registry-case
 'classic-continuation-aligns '(portable core)
(test-equal 'classic-continuation-aligns
             "> . (+ 1\n2)\n= 3\n\n> _ exit closed-ok\n"
             (cli-repl-rendered-from-string "(+ 1\n2)\n" "repl-main" 'classic
               #f)))
;; A deeper continuation just adds another `. ' gutter -- no nesting count.
(testing-registry-case
 'classic-continuation-no-count '(portable core)
(test-equal 'classic-continuation-no-count
             "> . . (+ (* 2\n3)\n4)\n= 10\n\n> _ exit closed-ok\n"
             (cli-repl-rendered-from-string "(+ (* 2\n3)\n4)\n" "repl-main"
                                      'classic #f)))
;; The comment chrome's continuation gutter is width-matched alignment dots
;; (one dot per ordinal digit), with no nesting count.
(testing-registry-case
 'comment-continuation-dots '(portable core)
(test-assert 'comment-continuation-dots
             (string-contains?
             (cli-repl-rendered-from-string "(+ (* 2\n3)\n4)\n" "repl-main"
                                            'comment #f)
             "#| . |# ")))
(testing-registry-case
 'quiet-results-only '(portable core)
(test-equal 'quiet-results-only
             "3\n"
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'quiet
               #f)))
(testing-registry-case
 'silent-suppresses-all '(portable core)
(test-equal 'silent-suppresses-all
             ""
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'silent
               #f)))

;;;; A recoverable condition still renders under a human chrome

(testing-registry-case
 'comment-condition-marker '(portable core)
(let ((rendered
       (cli-repl-rendered-from-string "undefined-name\n" "repl-main"
                                      'comment #f)))
  (test-assert 'comment-condition-marker (string-contains? rendered
    ";;   !! "))))

;;;; Program output: `comment' owns it (control channel), others keep it raw

;; Every R7RS host's display/newline needs the write/base bindings; importing
;; them first makes the program-output cases deterministic across hosts.
(define output-prelude "(import (scheme base) (scheme write))\n")

;; `comment' renders each printed line as a `;;   :: ' comment aligned to the
;; result marker, on the control channel, so the whole transcript -- program
;; output included -- is line comments and bare source.
(testing-registry-case
 'comment-output-on-control-channel '(portable core)
(test-equal 'comment-output-on-control-channel
             (string-append
        "#| 1 |# (import (scheme base) (scheme write))\n;;   => (unspecified)\n\
;;\n"
        "#| 2 |# (display \"hi\\n\")\n;;   :: hi\n;;   => (unspecified)\n;;\n"
        "#| 3 |# (+ 1 1)\n;;   => 2\n;;\n#| 4 |# ;;   __ exit closed-ok\n")
             (cli-repl-rendered-from-string
        (string-append output-prelude "(display \"hi\\n\")\n(+ 1 1)\n")
        "repl-main" 'comment #f)))
;; Because `comment' owns program output, stdout (the program-output stream)
;; carries nothing under it.
(testing-registry-case
 'comment-output-leaves-stdout-clean '(portable core)
(test-equal 'comment-output-leaves-stdout-clean
             ""
             (cdr (cli-repl-capture-from-string
             (string-append output-prelude "(display \"hi\\n\")\n(+ 1 1)\n")
             "repl-main" 'comment #f))))
;; Multi-line output is one `;;   :: ' comment per line.
(testing-registry-case
 'comment-output-multi-line '(portable core)
(test-assert 'comment-output-multi-line
             (string-contains?
             (cli-repl-rendered-from-string
              (string-append output-prelude
                             "(begin (display \"a\")(newline)(display \"b\")"
                             "(newline) 0)\n")
              "repl-main" 'comment #f)
             ";;   :: a\n;;   :: b\n;;   => 0")))
;; Output that ends without a newline still gets a terminating one so the
;; comment
;; closes before the result line.
(testing-registry-case
 'comment-output-no-trailing-newline '(portable core)
(test-assert 'comment-output-no-trailing-newline
             (string-contains?
             (cli-repl-rendered-from-string
              (string-append output-prelude "(begin (display \"x\") 5)\n")
              "repl-main" 'comment #f)
             ";;   :: x\n;;   => 5")))
;; `classic' (and every non-`comment' chrome) leaves program output raw on its
;; own stream; the control channel carries records only, not the printed text.
;; The printed value (12321) is computed so it is absent from the echoed
;; source.
(testing-registry-case
 'classic-output-raw-on-stdout '(portable core)
(let ((classic (cli-repl-capture-from-string
                (string-append output-prelude
                               "(begin (display (* 111 111))(newline) 1)\n")
                "repl-main" 'classic #f)))
  (test-equal 'classic-output-raw-on-stdout "12321\n" (cdr classic))
  (test-assert 'classic-output-not-on-control-channel
             (not (string-contains? (car classic) "12321")))))
;; The `comment' control-channel transcript round-trips through a fresh
;; session:
;; the commented output is inert on replay and the re-evaluated forms
;; regenerate
;; it, so the per-submission results match the original input's.
(testing-registry-case
 'comment-output-transcript-replays '(portable core)
(let* ((input (string-append output-prelude
                             "(display \"hello\\n\")\n"
                             "(begin (display \"x\")(newline) 42)\n"
                             "(+ 2 3)\n"))
       (transcript (cli-repl-rendered-from-string input "repl-main" 'comment
         #f)))
  (test-equal 'comment-output-transcript-replays
             (result-displays (drive input))
             (result-displays (drive transcript)))))

;;;; Color is TTY-gated, overridable, and strips when piped or NO_COLOR is set

(testing-registry-case
 'color-never-off '(portable core)
(test-equal 'color-never-off #f (cli-repl-chrome-color? 'never #f #t)))
(testing-registry-case
 'color-always-on '(portable core)
(test-equal 'color-always-on #t (cli-repl-chrome-color? 'always #t #f)))
(testing-registry-case
 'color-auto-tty-on '(portable core)
(test-equal 'color-auto-tty-on #t (cli-repl-chrome-color? 'auto #f #t)))
(testing-registry-case
 'color-auto-piped-off '(portable core)
(test-equal 'color-auto-piped-off #f (cli-repl-chrome-color? 'auto #f #f)))
(testing-registry-case
 'color-auto-no-color-off '(portable core)
(test-equal 'color-auto-no-color-off #f (cli-repl-chrome-color? 'auto #t #t)))

;; The painter adds ANSI SGR only when color is enabled.
(testing-registry-case
 'paint-color-emits-escape '(portable core)
(test-assert 'paint-color-emits-escape
             (string-contains?
             (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main" 'comment
               #t)
             escape)))
(testing-registry-case
 'paint-plain-has-no-escape '(portable core)
(test-assert 'paint-plain-has-no-escape
             (not (string-contains?
              (cli-repl-rendered-from-string "(+ 1 2)\n" "repl-main"
                                             'comment #f)
              escape))))

;;;; Option parsing: --session, --chrome, --color (inline and spaced)

(testing-registry-case
 'parse-session '(portable core)
(let ((options (cli-repl-parse-options
                (list "--chrome" "classic" "--color=always" "--session"
                  "demo"))))
  (test-equal 'parse-session "demo" (cdr (assq 'session options)))
  (test-equal 'parse-chrome 'classic (cdr (assq 'chrome options)))
  (test-equal 'parse-color-inline 'always (cdr (assq 'color options)))))
(testing-registry-case
 'parse-color-spaced '(portable core)
(let ((options (cli-repl-parse-options (list "--color" "never"))))
  (test-equal 'parse-color-spaced 'never (cdr (assq 'color options)))
  (test-equal 'parse-chrome-default 'comment (cdr (assq 'chrome options)))
  (test-equal 'parse-session-default "repl-main" (cdr (assq 'session
    options)))))
;; A bare `--repl' token (passed through from the compiled host dispatch) and
;; any
;; unrecognized argument are ignored, leaving the defaults intact.
(testing-registry-case
 'parse-ignores-repl-token '(portable core)
(let ((options (cli-repl-parse-options (list "--repl"))))
  (test-equal 'parse-ignores-repl-token 'comment (cdr (assq 'chrome
    options)))))
;; `--replay FILE' carries the transcript path; the default is #f (stdin
;; session).
(testing-registry-case
 'parse-replay '(portable core)
(test-equal 'parse-replay
             "t.scm"
             (cdr (assq 'replay (cli-repl-parse-options (list "--replay"
               "t.scm"))))))
(testing-registry-case
 'parse-replay-default '(portable core)
(test-equal 'parse-replay-default
             #f
             (cdr (assq 'replay (cli-repl-parse-options '())))))

;;;; Transcript capture and replay (docs/repl-interaction-contract.md)

;; Serialize a record stream through the consent writer -- the canonical
;; capture
;; form.  Comparing serialized streams is host-portable: value-equal canonical
;; numbers render identically, so two streams serialize the same exactly when
;; they carry the same data, sidestepping per-host record identity.
(define (serialize records)
  (map consent-datum->external records))

;; A captured transcript, serialized to the datum stream, reloads with the
;; standard reader (plain data) and carries exactly the complete submissions a
;; replay re-feeds, so the saved-file round-trip replays to the same stream.
(testing-registry-case
 'reload-record-count '(portable core)
(let* ((captured (drive "(define base 7)\n(* base 3)\n"))
       (text (apply string-append
                    (map (lambda (r)
                           (string-append (consent-datum->external r) "\n"))
                         captured)))
       (reloaded (cli-repl-records-from-datum-stream text)))
  (test-equal 'reload-record-count (length captured) (length reloaded))
  (test-equal 'reload-extracts-submissions
             '("(define base 7)" "(* base 3)")
             (cli-repl-submissions-from-records reloaded))
  ;; Replaying the reloaded transcript reproduces the captured record stream.
  (test-equal 'reload-replays-equal
             (serialize captured)
             (serialize (cli-repl-replay-records reloaded "project-main")))))

;; An EOF-truncated partial form is not a complete submission, so it
;; contributes
;; no replayable source.
(testing-registry-case
 'submissions-skip-incomplete '(portable core)
(test-equal 'submissions-skip-incomplete
             '()
             (cli-repl-submissions-from-records (drive "(+ 1\n"))))

;; A pure transcript replays to an EQUAL record stream, and the report says so.
(testing-registry-case
 'replay-input '(portable core)
(let* ((captured (drive
  "(import (scheme base))\n(define base 20)\n(* base 3)\n"))
       (replayed (cli-repl-replay-records captured "project-main"))
       (report (cli-repl-replay-report captured replayed)))
  (test-equal 'replay-input
             "(import (scheme base))\n(define base 20)\n(* base 3)\n"
             (cli-repl-replay-input captured))
  (test-equal 'replay-pure-roundtrip (serialize captured) (serialize replayed))
  (test-equal 'replay-report-reproduced 'reproduced (field report 'status))
  (test-equal 'replay-report-no-divergences '() (field report 'divergences))
  (test-equal 'replay-report-submission-count
             (portable-host-number 3)
             (consent-number-value (field report 'submissions)))))

;; A live host effect cannot be reproduced under a weaker replay posture.  A
;; submission that resolved the session interaction environment as a result
;; when
;; captured fails closed as a condition when replayed under a denying posture;
;; the report records that divergence rather than letting it pass silently
;; (docs "Capture and Replay": effectful forms fail closed, not silently).
(testing-registry-case
 'replay-effect-captured-results '(portable core)
(let* ((captured (drive (string-append
                         "(import (scheme base) (scheme repl))\n"
                         "(interaction-environment)\n")))
       (replayed (cli-repl-replay-records
                  captured "project-main"
                  '((policy-actions (standard-host-effect . deny)))))
       (report (cli-repl-replay-report captured replayed)))
  ;; Capture: both forms succeeded (two results, no conditions).
  (test-equal 'replay-effect-captured-results 2 (count-of captured
    'repl-result))
  (test-equal 'replay-effect-captured-no-conditions
             0
             (count-of captured 'repl-condition))
  ;; Replay denied the effect: the interaction-environment form is a condition.
  (test-equal 'replay-effect-replayed-results 1 (count-of replayed
    'repl-result))
  (test-equal 'replay-effect-replayed-conditions 1 (count-of replayed
    'repl-condition))
  ;; The report flags the result -> condition divergence with its source.
  (test-equal 'replay-report-status-diverged 'diverged (field report 'status))
  (let ((divergence (car (field report 'divergences))))
    (test-equal 'replay-divergence-source
             "(interaction-environment)"
             (field divergence 'source))
    (test-equal 'replay-divergence-captured-kind
             'result
             (field (assq 'captured (cdr divergence)) 'kind))
    (test-equal 'replay-divergence-replayed-kind
             'condition
             (field (assq 'replayed (cdr divergence)) 'kind)))))

(testing-runner-main "Consent Repl portable tests" (command-line))
