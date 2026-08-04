;;; Portable process-boundary lane for the native CLI and daemon host adapter.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program is the `(process-boundary-suite native-cli)' lane running on
;;; the
;;; portable Consent Scheme runtime. It runs under every R7RS host shard,
;;; drives
;;; the host-neutral adapter (cli native-cli), and -- on hosts whose process
;;; module is available -- spawns, streams, waits for, signals, and reaps a
;;; real
;;; child process through (cli process-host). It asserts the same
;;; Scheme-readable
;;; boundary records the portable validator and the Emacs lanes use, so the
;;; non-Emacs hosts reach parity with the Emacs bootstrap.
;;;
;;; Host-neutral checks -- record shape, fail-closed denials, vocabulary, and
;;; the
;;; interpreted/compiled record-shape alignment -- always run.  The real-spawn
;;; checks run only when `cli-host-available?' is true; a host without a
;;; process
;;; module reports an explicit, non-silent skip and still validates the rest.

(import (scheme base)
        (scheme write)
        (scheme file)
        (scheme read)
        (scheme process-context)
        (cli native-cli)
        (cli process-host)
        (testing registry)
        (testing runner)
        (stdlib testing))

;;;; Datum navigation over the live record lists returned by execute

;; Return RECORD's field forms, treating a leading sub-list as a headless
;; record.
(define (record-fields record)
  (if (pair? (car record)) record (cdr record)))

;; Return the (NAME ...) field of RECORD, or #f.  When RECORD is itself a
;; headed (NAME ...) form -- as a `payload' value like (exit-status 0) is --
;; RECORD is its own field.
(define (field record name)
  (if (and (pair? record) (eq? (car record) name))
      record
      (let loop ((fields (record-fields record)))
        (cond
         ((null? fields) #f)
         ((and (pair? (car fields)) (eq? (caar fields) name)) (car fields))
         (else (loop (cdr fields)))))))

;; Return the single value after RECORD field NAME, or #f.
(define (field-value record name)
  (let ((entry (field record name)))
    (and entry (cadr entry))))

;; Return the first record in RECORDS whose head symbol is KIND, or #f.
(define (record-of records kind)
  (cond
   ((null? records) #f)
   ((eq? (car (car records)) kind) (car records))
   (else (record-of (cdr records) kind))))

;; Return the first adapter-event in RECORDS whose `kind' field is KIND, or #f.
(define (event-of-kind records kind)
  (cond
   ((null? records) #f)
   ((and (eq? (car (car records)) 'adapter-event)
         (eq? (field-value (car records) 'kind) kind))
    (car records))
   (else (event-of-kind (cdr records) kind))))

;; Return #t when ITEM is equal? to some member of LIST.
(define (in-set? item list)
  (cond
   ((null? list) #f)
   ((equal? item (car list)) #t)
   (else (in-set? item (cdr list)))))

;;;; Outcome accessors

(define (outcome-exit outcome) (car outcome))
;; Return the boundary record stream from an execute OUTCOME.
(define (outcome-records outcome) (cadr outcome))
;; Return the approval prompt list from an execute OUTCOME.
(define (outcome-prompts outcome) (list-ref outcome 2))

;;;; Fixture vocabulary (standard reader only)

(define fixture
  (call-with-input-file "fixtures/host-adapters/native-cli-daemon.scm" read))

;; Return the adapter declaration form from the fixture.
(define (adapter-declaration)
  (field-value fixture 'adapter))

;; Return the adapter declaration field named NAME.
(define (vocabulary name)
  (field-value (adapter-declaration) name))

;;;; Host-neutral checks: denials fail closed before any host operation

(testing-registry-case
 'batch-deny-exit '(portable core)
(let ((outcome (cli-native-cli-execute
                '((subcommand . "process-run") (mode . "batch")
                  (command . "/bin/echo") (child-arguments
                    "should-not-run")))))
  (test-equal 'batch-deny-exit 3 (outcome-exit outcome))
  (let ((decision (record-of (outcome-records outcome) 'capability-decision))
        (error-datum (record-of (outcome-records outcome) 'adapter-error)))
    (test-equal 'batch-deny-status 'denied (field-value decision 'status))
    (test-equal 'batch-deny-kind
             'noninteractive-confirmation-unavailable
             (field-value error-datum 'kind))
    (test-assert 'batch-deny-audited
             (record-of (outcome-records outcome) 'adapter-audit))
    ;; No result and no child-output event mean the child never spawned.
    (test-equal 'batch-deny-no-result
             #f
             (record-of (outcome-records outcome) 'adapter-result))
    (test-equal 'batch-deny-no-stdout
             #f
             (event-of-kind (outcome-records outcome) 'stdout)))))

(testing-registry-case
 'stdin-deny-exit '(portable core)
(let ((outcome (cli-native-cli-execute
                '((subcommand . "stdin-read") (mode . "batch")))))
  (test-equal 'stdin-deny-exit 3 (outcome-exit outcome))
  (test-equal 'stdin-deny-kind
             'noninteractive-confirmation-unavailable
             (field-value (record-of (outcome-records outcome) 'adapter-error)
               'kind))
  (test-equal 'stdin-deny-no-result
             #f
             (record-of (outcome-records outcome) 'adapter-result))))

(testing-registry-case
 'stale-exit '(portable core)
(let ((outcome (cli-native-cli-execute
                '((subcommand . "process-status") (mode . "daemon")
                  (channel . #t) (job-id . "h-job-42")
                  (job-state . "stale")))))
  (test-equal 'stale-exit 3 (outcome-exit outcome))
  (let* ((error-datum (record-of (outcome-records outcome) 'adapter-error))
         (condition (field-value error-datum 'condition)))
    (test-equal 'stale-kind 'stale-handle (field-value error-datum 'kind))
    (test-equal 'stale-handle 'h-job-42 (field-value error-datum 'handle))
    (test-assert 'stale-condition condition)
    (test-equal 'stale-condition-kind 'stale-handle (field-value condition
      'kind))
    (test-equal 'stale-no-result
             #f
             (record-of (outcome-records outcome) 'adapter-result)))))

;;;; Host-neutral checks: vocabulary and interpreted/compiled record alignment

(testing-registry-case
 'event-kind-in-vocabulary '(portable core)
(let* ((approval (cli-native-cli-execute
                  '((subcommand . "process-status") (mode . "cli")
                    (job-id . "h-job-1") (job-state . "live"))))
       (denial (cli-native-cli-execute
                '((subcommand . "process-run") (mode . "batch")
                  (command . "/bin/echo") (child-arguments "x")))))
  ;; Every emitted event kind and the denial error kind are declared
  ;; vocabulary.
  (for-each
   (lambda (record)
     (if (eq? (car record) 'adapter-event)
         (test-assert 'event-kind-in-vocabulary
             (in-set? (field-value record 'kind)
                              (vocabulary 'event-kinds)))))
   (outcome-records approval))
  (test-assert 'error-kind-in-vocabulary
             (in-set? (field-value
                        (record-of (outcome-records denial) 'adapter-error)
                        'kind)
                       (vocabulary 'error-kinds)))))

(testing-registry-case
 'interpreted-execution '(portable core)
(let* ((interpreted (cli-native-cli-execute
                     '((subcommand . "process-status") (mode . "cli")
                       (job-id . "h-job-1") (job-state . "live")
                       (execution . "interpreted"))))
       (compiled (cli-native-cli-execute
                  '((subcommand . "process-status") (mode . "cli")
                    (job-id . "h-job-1") (job-state . "live")
                    (execution . "compiled"))))
       (interpreted-result (record-of (outcome-records interpreted)
                                      'adapter-result))
       (compiled-result (record-of (outcome-records compiled)
                                   'adapter-result)))
  (test-equal 'interpreted-execution
             'interpreted
             (field-value interpreted-result 'execution))
  (test-equal 'compiled-execution
             'compiled
             (field-value compiled-result 'execution))
  ;; The decision and request records are identical across execution
  ;; strategies.
  (test-equal 'request-shape-aligned
             (record-of (outcome-records compiled) 'capability-request)
             (record-of (outcome-records interpreted) 'capability-request))
  (test-equal 'decision-shape-aligned
             (record-of (outcome-records compiled) 'capability-decision)
             (record-of (outcome-records interpreted) 'capability-decision))))

;;;; Real process-boundary checks (only when a host process module is
;;;; available)

(testing-registry-case
 'run-exit '(portable core)
(if (not (cli-host-available?))
    (begin
      (display
       "SKIP native-cli process-boundary: no host process module on this host")
      (newline))
    (begin
      ;; Spawn, stream stdout, and wait for a zero exit status.
      (let ((outcome (cli-native-cli-execute
                      '((subcommand . "process-run") (mode . "cli")
                        (terminal . #t) (command . "/bin/echo")
                        (child-arguments "portable-stdout")))))
        (test-equal 'run-exit 0 (outcome-exit outcome))
        (let ((stdout-event (event-of-kind (outcome-records outcome) 'stdout))
              (exit-event (event-of-kind (outcome-records outcome)
                                         'process-exit)))
          (test-assert 'run-stdout-event stdout-event)
          (test-equal 'run-stdout-payload
             "portable-stdout\n"
             (field-value stdout-event 'payload))
          (test-equal 'run-exit-status
             0
             (field-value (field-value exit-event 'payload) 'exit-status))
          (test-assert 'run-result
             (record-of (outcome-records outcome) 'adapter-result))))

      ;; A nonzero child exit status is waited for and recorded.
      (let ((outcome (cli-native-cli-execute
                      '((subcommand . "process-run") (mode . "batch")
                        (approval . #t) (command . "/bin/sh")
                        (child-arguments "-c" "exit 7")))))
        (test-equal 'nonzero-exit-status
             7
             (field-value (field-value
                             (event-of-kind (outcome-records outcome)
                                            'process-exit)
                             'payload)
                            'exit-status)))

      ;; Child stderr streams as a stderr event.
      (let ((outcome (cli-native-cli-execute
                      '((subcommand . "process-run") (mode . "batch")
                        (approval . #t) (command . "/bin/sh")
                        (child-arguments "-c" "echo portable-stderr 1>&2")))))
        (test-equal 'stderr-payload
             "portable-stderr\n"
             (field-value (event-of-kind (outcome-records outcome) 'stderr)
                            'payload)))

      ;; A host-backed stdin port reaches the child while the approval prompt
      ;; stays on the diagnostic stream, never on the record stream. Scratch
      ;; lives inside the working tree so the capability-scoped self-hosted
      ;; runner (consent --host-run) can write it too.
      (let ((stdin-file
             "tests/scheme/scratch/consent-native-cli-portable-stdin"))
        ;; `call-with-output-file' errors on an existing file under some hosts,
        ;; so clear any leftover from a previous host run before writing.
        (if (file-exists? stdin-file) (delete-file stdin-file))
        (call-with-output-file stdin-file
          (lambda (port) (write-string "portable-stdin-payload" port)))
        (let ((outcome (cli-native-cli-execute
                        (list '(subcommand . "process-run") '(mode . "cli")
                              '(terminal . #t) '(command . "cat")
                              (cons 'stdin-file stdin-file)))))
          (test-equal 'stdin-payload
             "portable-stdin-payload"
             (field-value (event-of-kind (outcome-records outcome) 'stdout)
                              'payload))
          ;; The prompt is returned for the diagnostic stream, separate from
          ;; the
          ;; child's stdin port, which delivered the full payload above.
          (test-assert 'stdin-prompt-present
             (pair? (outcome-prompts outcome))))
        (if (file-exists? stdin-file) (delete-file stdin-file)))

      ;; A granted cwd is observed by a real child.
      (let ((outcome (cli-native-cli-execute
                      '((subcommand . "process-run") (mode . "batch")
                        (approval . #t) (command . "pwd") (cwd . "/")))))
        (test-equal 'cwd-grant
             "/\n"
             (field-value (event-of-kind (outcome-records outcome) 'stdout)
                            'payload)))

      ;; A granted environment variable is observed by a real child.
      (let ((outcome (cli-native-cli-execute
                      (list '(subcommand . "process-run") '(mode . "batch")
                            '(approval . #t) '(command . "/bin/sh")
                            '(child-arguments "-c"
                              "printf %s \"$CONSENT_GRANT\"")
                            (list 'environment
                                  (cons "CONSENT_GRANT" "granted-value"))))))
        (test-equal 'environment-grant
             "granted-value"
             (field-value (event-of-kind (outcome-records outcome) 'stdout)
                            'payload)))

      ;; A real child is signaled and reaped; the status is signal-terminated.
      (let* ((outcome (cli-native-cli-execute
                       '((subcommand . "process-signal") (mode . "cli")
                         (terminal . #t) (job-id . "h-job-sig")
                         (signal . "TERM"))))
             (exit-event (event-of-kind (outcome-records outcome)
                                        'process-exit)))
        (test-equal 'signal-exit 0 (outcome-exit outcome))
        (test-equal 'signal-name
             'TERM
             (field-value (field-value exit-event 'payload) 'signal))
        (test-assert 'signal-terminated
             (>= (field-value (field-value exit-event 'payload)
                                     'exit-status)
                        128))))))

;;;; Report

(testing-runner-main "Consent Native Cli Daemon Process portable tests"
  (command-line))
