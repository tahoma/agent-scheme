;;; Portable half of the shared cross-host REPL parity conformance suite.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and drives the host-neutral
;;; REPL parity corpus (fixtures/repl/parity-cases.scm) against the portable
;;; terminal REPL shell `(cli repl-shell)'. It is the portable twin of the
;;; Emacs
;;; runner tests/consent-repl-parity-test.el: both read the SAME corpus and
;;; assert the SAME expected record sequence for each scenario, so any
;;; divergence
;;; from the cross-host REPL interaction contract
;;; (docs/repl-interaction-contract.md) fails on the diverging host.
;;;
;;; The corpus enumerates every record a turn produces.  This runner asserts
;;; per-kind record counts and the contract-meaningful fields of each record. A
;;; `repl-result'/`repl-condition' is correlated to its submission by the
;;; `(submission sub-N)' field -- the durable join named in the contract's
;;; forward-compatibility section -- while prompts, submissions, and the exit
;;; are
;;; matched positionally within their kind.

(import (scheme base)
        (scheme file)
        (scheme read)
        (scheme write)
        (only (consent reader)
              consent-number? consent-number-value consent-datum->external)
        (cli repl-shell)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;;;; Tagged-list helpers (records and expectation patterns share this shape)

;; Return the single value of field NAME in tagged list DATUM, or #f.  Records,
;; expectation patterns, and the suite are tagged: `(tag (field value) ...)'.
(define (field datum name)
  (let ((entry (assq name (cdr datum))))
    (and entry (pair? (cdr entry)) (cadr entry))))

;; Return field NAME from an untagged CASE alist `((field value) ...)', or #f.
(define (case-field case name)
  (let ((entry (assq name case)))
    (and entry (pair? (cdr entry)) (cadr entry))))

;; Return the leading tag symbol of RECORD or pattern P.
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

;; Return the number of RECORDS whose kind is TAG.
(define (count-of records tag)
  (length (records-of records tag)))

;; Return the distinct kinds appearing in either expected or actual records.
(define (union-kinds . record-lists)
  (let loop ((lists record-lists) (seen '()))
    (cond
     ((null? lists) (reverse seen))
     ((null? (car lists)) (loop (cdr lists) seen))
     (else
      (let ((k (kind (caar lists))))
        (loop (cons (cdar lists) (cdr lists))
              (if (memq k seen) seen (cons k seen))))))))

;;;; Corpus loading and option conversion

;; Load the canonical REPL parity corpus through the host reader.
(define (read-suite)
  (call-with-input-file "fixtures/repl/parity-cases.scm" read))

;; Extract the case list from the parity SUITE datum.
(define (suite-cases suite)
  (let ((entry (assq 'cases (cdr suite))))
    (if entry (cdr entry) '())))

;; Return #t when V is an association written as `((key value) ...)'.
(define (option-assoc-form? v)
  (and (pair? v)
       (pair? (car v))
       (= (length (car v)) 2)
       (symbol? (caar v))))

;; Convert a corpus option value (record-style alist or atom) to a dotted
;; alist.
(define (option-value v)
  (if (option-assoc-form? v)
      (map (lambda (entry) (cons (car entry) (option-value (cadr entry)))) v)
      v))

;; Convert a case's `(options ...)' field to the evaluator option alist.
(define (case-options case)
  (map (lambda (entry) (cons (car entry) (option-value (cadr entry))))
       (case-field case 'options)))

;;;; Expectation matching

;; Kinds whose pattern is correlated to its submission rather than positional.
(define (correlated-kind? k)
  (memq k '(repl-result repl-condition)))

;; Return the actual record of kind TAG whose `submission' field is SUB, or #f.
(define (find-by-submission records tag sub)
  (let loop ((records (records-of records tag)))
    (cond
     ((null? records) #f)
     ((equal? (field (car records) 'submission) sub) (car records))
     (else (loop (cdr records))))))

;; Build a mutable per-kind queue of ACTUAL records, in order.
(define (make-kind-queues records)
  (let ((table '()))
    (for-each
     (lambda (record)
       (let ((cell (assq (kind record) table)))
         (if cell
             (set-cdr! cell (cons record (cdr cell)))
             (set! table (cons (cons (kind record) (list record)) table)))))
     records)
    (for-each (lambda (cell) (set-cdr! cell (reverse (cdr cell)))) table)
    table))

;; Pop and return the next queued record of kind TAG, or #f when exhausted.
(define (pop-queue! table tag)
  (let ((cell (assq tag table)))
    (if (and cell (pair? (cdr cell)))
        (let ((record (cadr cell)))
          (set-cdr! cell (cddr cell))
          record)
        #f)))

;; Return #t when ACTUAL satisfies EXPECTED, which is either an atom (compared
;; with equal?) or a nested record pattern `(KIND (field value) ...)'.
;; Numeric contract fields embed canonical number records while the corpus
;; writes plain literals, so numbers compare by host payload on every host.
(define (value-match? actual expected)
  (cond
   ((pair? expected)
    (and (pair? actual)
         (eq? (kind actual) (kind expected))
         (fields-match? actual (cdr expected))))
   ((or (number? expected) (consent-number? expected))
    (and (or (number? actual) (consent-number? actual))
         (equal? (consent-number-value actual)
                 (consent-number-value expected))))
   (else (equal? actual expected))))

;; Return #t when RECORD's fields all satisfy the FIELDS expectation list.
(define (fields-match? record fields)
  (let loop ((fields fields))
    (cond
     ((null? fields) #t)
     ((value-match? (field record (car (car fields))) (cadr (car fields)))
      (loop (cdr fields)))
     (else #f))))

;; Assert one expected RECORD pattern against ACTUAL for case ID.
(define (match-record id pattern actual)
  (for-each
   (lambda (entry)
     (let* ((fname (car entry))
            (expected (cadr entry))
            (got (field actual fname)))
       (test-assert (list id (kind pattern) fname)
                    (value-match? got expected))))
   (cdr pattern)))

;; Drive one CASE against the portable REPL and assert its expected records.
(define (run-case case)
  (let* ((id (case-field case 'id))
         (input (case-field case 'input))
         (session (case-field case 'session))
         (options (case-options case))
         (expect (case-field case 'expect))
         (actual (cli-repl-records-from-string input session options))
         (queues (make-kind-queues actual)))
    (for-each
     (lambda (k)
       (test-equal (list id 'count k) (count-of expect k) (count-of actual k)))
     (union-kinds expect actual))
    (for-each
     (lambda (pattern)
       (if (correlated-kind? (kind pattern))
           (let* ((sub (field pattern 'submission))
                  (rec (find-by-submission actual (kind pattern) sub)))
             (if rec
                 (match-record id pattern rec)
                 (test-equal (list id (kind pattern) 'submission sub)
                             'present 'missing)))
           (let ((rec (pop-queue! queues (kind pattern))))
             (if rec
                 (match-record id pattern rec)
                 (test-equal (list id (kind pattern)) 'present 'missing)))))
     expect)
    (run-roundtrip id case actual session options)))

;;;; Capture/replay round-trip (docs/repl-interaction-contract.md, "Capture and
;;;; Replay")

;; Serialize a record stream through the consent writer.  Comparing serialized
;; streams is host-portable: value-equal canonical numbers render identically,
;; so two streams are byte-equal exactly when they read back the same data,
;; sidestepping per-host record identity.
(define (serialize-records records)
  (map consent-datum->external records))

;; Replay the captured record stream to a fresh session with the same options
;; and compare. A `reproduced' case must replay to an EQUAL stream (every input
;; chunk became a complete submission); a `partial' case must NOT (it drops an
;; unreplayable bare reader condition or EOF-truncated incomplete form), so the
;; contract's reproduces-vs-cannot split is asserted in both directions.
(define (run-roundtrip id case actual session options)
  (let* ((mode (case-field case 'replay))
         (replayed (cli-repl-replay-records actual session options))
         (same? (equal? (serialize-records actual)
                        (serialize-records replayed))))
    (test-assert (list id 'has-replay-field) (if mode #t #f))
    (if (eq? mode 'reproduced)
        (test-assert (list id 'replay-reproduced) same?)
        (test-assert (list id 'replay-partial) (not same?)))))

;;;; Stream-separation parity check (not record-stream shaped, asserted
;;;; directly)

;; Drive a session with program output and assert the contract separation:
;; program output reaches the program-output stream, never a result rendering.
(define (run-stream-separation-check)
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
      (test-equal 'stream-separation-program-output
             "emitted"
             (apply string-append (reverse output)))
      (let ((records (reverse records)))
        (test-equal 'stream-separation-result-count 3 (count-of records
          'repl-result))
        (test-assert 'stream-separation-has-exit
             (> (count-of records 'repl-exit) 0))
        (for-each
         (lambda (result)
           (test-assert 'stream-separation-clean-result
             (not (equal? (field result 'display) "emitted"))))
         (records-of records 'repl-result))))))

;;;; Drive the corpus

;; Canonical parity suite loaded once for validation and execution.
(define suite (read-suite))

;; Shared parity case list extracted from the canonical suite.
(define cases (suite-cases suite))

(testing-registry-case
 'parity-suite-tag '(portable core)
(test-equal 'parity-suite-tag 'consent-fixture-suite (car suite)))
(testing-registry-case
 'parity-suite-kind '(portable core)
(test-equal 'parity-suite-kind 'repl-parity (field suite 'kind)))
(testing-registry-case
 'parity-suite-version '(portable core)
(test-equal 'parity-suite-version 1 (field suite 'version)))
(testing-registry-case
 'parity-suite-has-cases '(portable core)
(test-assert 'parity-suite-has-cases (pair? cases)))
(testing-registry-case
 'parity-suite-contract '(portable core)
(let ((contract (field suite 'contract)))
  (test-assert 'parity-suite-contract
             (and (pair? contract)
                   (eq? (car contract) 'repl-interaction-contract)))
  (test-equal 'parity-suite-contract-version 1 (field contract 'version))))

;; Case ids are unique so a divergence is reported against a stable name.
(testing-registry-case
 'duplicate-case-id '(portable core)
(let loop ((rest cases) (seen '()))
  (cond
   ((null? rest) #t)
   ((memq (case-field (car rest) 'id) seen)
    (test-equal 'duplicate-case-id 'unique (case-field (car rest) 'id)))
   (else (loop (cdr rest) (cons (case-field (car rest) 'id) seen))))))

(testing-registry-case
 'consent-repl-parity-case-7 '(portable core)
(for-each run-case cases))
(testing-registry-case
 'consent-repl-parity-case-8 '(portable core)
(run-stream-separation-check))

(testing-runner-main "Consent Repl Parity portable tests" (command-line))
