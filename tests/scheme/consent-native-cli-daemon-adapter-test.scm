;;; Portable validator for the native CLI and daemon host adapter fixture.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under any available R7RS implementation, reads the
;;; checked-in native-cli-daemon adapter declaration and capability manifest as
;;; Scheme data, and validates library names, authority classes, handle kinds,
;;; event kinds, error kinds, capability and boundary record shapes, and the
;;; mock noninteractive-confirmation and stale-handle denials. It uses only the
;;; standard R7RS reader, so it needs no Consent runtime libraries and starts
;;; no
;;; real process, terminal, socket, or daemon boundary.

(import (scheme base)
        (scheme file)
        (scheme read)
        (scheme write)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Return #t when PREDICATE accepts every value in VALUES.
(define (every? predicate values)
  (cond
   ((null? values) #t)
   ((predicate (car values)) (every? predicate (cdr values)))
   (else #f)))

;; Return #t when ITEM is equal? to some member of LIST.
(define (in-set? item list)
  (cond
   ((null? list) #f)
   ((equal? item (car list)) #t)
   (else (in-set? item (cdr list)))))

;; Return #t when LEFT and RIGHT hold the same members regardless of order.
(define (same-set? left right)
  (and (= (length left) (length right))
       (every? (lambda (item) (in-set? item right)) left)
       (every? (lambda (item) (in-set? item left)) right)))

;; Return RECORD's field forms, treating a leading head symbol as non-field
;; data
;; and a leading sub-list as the first field of a headless record.
(define (record-fields record)
  (if (pair? (car record)) record (cdr record)))

;; Return the (NAME ...) sub-form of RECORD, or #f when it is absent.
(define (field record name)
  (let loop ((fields (record-fields record)))
    (cond
     ((null? fields) #f)
     ((and (pair? (car fields)) (eq? (caar fields) name)) (car fields))
     (else (loop (cdr fields))))))

;; Return the single value following RECORD field NAME, or #f when absent.
(define (field-value record name)
  (let ((entry (field record name)))
    (and entry (cadr entry))))

;; Return #t when RECORD includes a field named NAME.
(define (field-present? record name)
  (if (field record name) #t #f))

;; Read the native-cli-daemon adapter fixture as a single Scheme datum.
(define (read-fixture)
  (call-with-input-file "fixtures/host-adapters/native-cli-daemon.scm" read))

;; Canonical fixture datum validated by the rest of this program.
(define fixture (read-fixture))

;; Adapter declaration section of the fixture.
(define adapter (field-value fixture 'adapter))

;; Capability manifest section of the fixture.
(define manifest (field-value fixture 'capability-manifest))

;; Library names the adapter declares it provides.
(define provided-libraries
  (map (lambda (entry) (cadr entry))
       (field-value adapter 'provides)))

;; Authority class entries declared by the adapter.
(define authority-entries (field-value adapter 'authority))

;; Authority class symbols declared by the adapter.
(define authority-classes
  (map (lambda (entry) (field-value entry 'class)) authority-entries))

;; Handle-kind entries declared by the adapter.
(define handle-entries (field-value adapter 'handle-kinds))

;; Handle-kind symbols declared by the adapter.
(define handle-kinds
  (map (lambda (entry) (field-value entry 'kind)) handle-entries))

;; Event-kind symbols declared by the adapter.
(define event-kinds (field-value adapter 'event-kinds))

;; Error-kind symbols declared by the adapter.
(define error-kinds (field-value adapter 'error-kinds))

;; Capability records declared by the manifest.
(define capabilities (field-value manifest 'capabilities))

;; Boundary record samples declared by the fixture.
(define records (field-value fixture 'records))

;; Mock denial scenarios declared by the fixture.
(define scenarios (field-value fixture 'scenarios))

;; Library names the contract requires the adapter to provide.
(define expected-libraries
  '((cli cwd)
    (cli file)
    (cli environment)
    (cli stdio)
    (cli terminal)
    (cli process)
    (cli daemon)
    (cli audit)
    (consent capability)
    (agent approval)
    (agent io)
    (agent session)))

;; Authority classes the contract requires the adapter to name.
(define expected-authority-classes
  '(read-only-observation
    filesystem-read
    filesystem-mutation
    terminal-io
    environment-observation
    environment-mutation
    process-observation
    process-control
    daemon-control
    audit-observation
    audit-export))

;; Handle kinds the contract requires the adapter to name.
(define expected-handle-kinds
  '(cwd
    directory
    file
    file-port
    stdio-port
    process-job
    process-port
    environment
    terminal
    daemon-client
    audit-sink
    session))

;; Event kinds the contract requires the adapter to name.
(define expected-event-kinds
  '(stdout
    stderr
    stdin-request
    process-exit
    approval-request
    approval-decision
    progress
    warning
    daemon-connected
    daemon-disconnected
    audit-rotated))

;; Error kinds the contract requires the adapter to name.
(define expected-error-kinds
  '(policy-denied
    approval-timeout
    noninteractive-confirmation-unavailable
    stale-handle
    invalid-handle
    unsupported-effect
    process-exit
    stdio-closed
    terminal-unavailable
    daemon-disconnected
    transport-error
    redaction-denied))

;; Required field names for each boundary record head.
(define record-required-fields
  '((capability-request id session adapter library binding domain operation
                        resource effect requires)
    (capability-decision id request status policy grant reason)
    (adapter-result id adapter mode execution session status value events audit
                    resource-usage)
    (adapter-event id adapter session kind source payload timestamp)
    (adapter-audit id adapter session request decision result sink redactions
                   timestamp)
    (adapter-error kind adapter session request decision message irritants)))

;; Return the authority entry whose class is CLASS, or #f when absent.
(define (authority-entry class)
  (let loop ((entries authority-entries))
    (cond
     ((null? entries) #f)
     ((eq? (field-value (car entries) 'class) class) (car entries))
     (else (loop (cdr entries))))))

;; Return the host effect the authority CLASS declares, or #f when absent.
(define (authority-effect class)
  (let ((entry (authority-entry class)))
    (and entry (field-value entry 'effect))))

;; Return the boundary record whose head symbol is HEAD, or #f when absent.
(define (record-by-head head)
  (let loop ((rest records))
    (cond
     ((null? rest) #f)
     ((eq? (car (car rest)) head) (car rest))
     (else (loop (cdr rest))))))

;; Return the scenario whose id is ID, or #f when absent.
(define (scenario-by-id id)
  (let loop ((rest scenarios))
    (cond
     ((null? rest) #f)
     ((eq? (field-value (car rest) 'id) id) (car rest))
     (else (loop (cdr rest))))))

;; Validate one capability record against the declared adapter vocabulary.
(define (check-capability capability)
  (let ((name (field-value capability 'name))
        (library (field-value capability 'library))
        (authority (field-value capability 'authority))
        (handle-kind (field-value capability 'handle-kind))
        (effect (field-value capability 'effect))
        (effect-path (field-value capability 'effect-path)))
    (test-assert (list name 'library) (in-set? library provided-libraries))
    (test-assert (list name 'authority) (in-set? authority authority-classes))
    (test-assert (list name 'handle-kind) (in-set? handle-kind handle-kinds))
    (test-equal (list name 'effect-path) 'shared-capability-request
      effect-path)
    (test-equal (list name 'effect) (authority-effect authority) effect)))

;; Validate one boundary record holds every field its head requires.
(define (check-record spec)
  (let* ((head (car spec))
         (required (cdr spec))
         (record (record-by-head head)))
    (test-assert (list head 'present) record)
    (if record
        (for-each
         (lambda (field-name)
           (test-assert (list head field-name)
             (field-present? record field-name)))
         required))))

;; Validate a denial SCENARIO denies before any host operation runs.
(define (check-denial-scenario id reason kind)
  (let ((scenario (scenario-by-id id)))
    (test-assert (list id 'present) scenario)
    (if scenario
        (let ((decision (field-value scenario 'decision))
              (error-form (field-value scenario 'error)))
          (test-equal (list id 'host-operation)
             'not-performed
             (field-value scenario 'host-operation))
          (test-equal (list id 'decision-status)
             'denied
             (field-value decision 'status))
          (test-equal (list id 'decision-reason)
             reason
             (field-value decision 'reason))
          (test-equal (list id 'error-kind) kind (field-value error-form
            'kind))
          (test-assert (list id 'error-kind-declared)
             (in-set? (field-value error-form 'kind) error-kinds))))))

;; Validate the fixture envelope and adapter identity.
(testing-registry-case
 'fixture-tag '(portable core)
(test-equal 'fixture-tag 'consent-host-adapter-fixture (car fixture)))
(testing-registry-case
 'fixture-id '(portable core)
(test-equal 'fixture-id 'native-cli-daemon-host-adapter (field-value fixture
  'id)))
(testing-registry-case
 'fixture-status '(portable core)
(test-equal 'fixture-status 'contract (field-value fixture 'status)))
(testing-registry-case
 'adapter-tag '(portable core)
(test-equal 'adapter-tag 'host-adapter (car adapter)))
(testing-registry-case
 'adapter-name '(portable core)
(test-equal 'adapter-name 'native-cli-daemon (field-value adapter 'name)))
(testing-registry-case
 'adapter-contract '(portable core)
(test-equal 'adapter-contract 'r7rs-small (field-value adapter 'contract)))
(testing-registry-case
 'manifest-adapter '(portable core)
(test-equal 'manifest-adapter 'native-cli-daemon (field-value manifest
  'adapter)))
(testing-registry-case
 'manifest-effect-path '(portable core)
(test-equal 'manifest-effect-path
             'shared-capability-request
             (field-value manifest 'effect-path)))

;; Validate adapter modes cover terminal, batch, and daemon use.
(testing-registry-case
 'mode-cli '(portable core)
(let ((modes (field-value adapter 'modes)))
  (test-assert 'mode-cli (in-set? 'cli modes))
  (test-assert 'mode-batch (in-set? 'batch modes))
  (test-assert 'mode-daemon (in-set? 'daemon modes))))

;; Validate interpreted and future compiled execution share the effect path.
(testing-registry-case
 'interpreted-effect-path '(portable core)
(let ((execution (field-value adapter 'execution)))
  (test-equal 'interpreted-effect-path
             'shared-capability-request
             (field-value (field execution 'interpreted) 'effect-path))
  (test-equal 'compiled-effect-path
             'shared-capability-request
             (field-value (field execution 'compiled) 'effect-path))))

;; Validate the declared vocabularies match the contract.
(testing-registry-case
 'provided-libraries '(portable core)
(test-assert 'provided-libraries
             (same-set? provided-libraries expected-libraries)))
(testing-registry-case
 'authority-classes '(portable core)
(test-assert 'authority-classes
             (same-set? authority-classes expected-authority-classes)))
(testing-registry-case
 'handle-kinds '(portable core)
(test-assert 'handle-kinds
             (same-set? handle-kinds expected-handle-kinds)))
(testing-registry-case
 'event-kinds '(portable core)
(test-assert 'event-kinds
             (same-set? event-kinds expected-event-kinds)))
(testing-registry-case
 'error-kinds '(portable core)
(test-assert 'error-kinds
             (same-set? error-kinds expected-error-kinds)))

;; Validate every capability against the declared adapter vocabulary.
(testing-registry-case
 'capabilities-present '(portable core)
(test-assert 'capabilities-present (pair? capabilities)))
(testing-registry-case
 'consent-native-cli-daemon-adapter-case-17 '(portable core)
(for-each check-capability capabilities))

;; Validate every boundary record carries its required fields.
(testing-registry-case
 'consent-native-cli-daemon-adapter-case-18 '(portable core)
(for-each check-record record-required-fields))

;; Validate the mock denials precede any allowed host operation.
(testing-registry-case
 'consent-native-cli-daemon-adapter-case-19 '(portable core)
(check-denial-scenario 'native-cli-daemon-noninteractive-denial
                       'noninteractive-confirmation-unavailable
                       'noninteractive-confirmation-unavailable))
(testing-registry-case
 'consent-native-cli-daemon-adapter-case-20 '(portable core)
(check-denial-scenario 'native-cli-daemon-stale-handle-denial
                       'stale-handle
                       'stale-handle))

;; Validate the stale-handle scenario nests a capability-error condition.
(testing-registry-case
 'stale-handle-condition '(portable core)
(let* ((scenario (scenario-by-id 'native-cli-daemon-stale-handle-denial))
       (error-form (and scenario (field-value scenario 'error)))
       (condition (and error-form (field-value error-form 'condition))))
  (test-assert 'stale-handle-condition condition)
  (if condition
      (test-equal 'stale-handle-condition-kind
             'stale-handle
             (field-value condition 'kind)))))

;; Report the aggregate result and fail the process on any mismatch.

(testing-runner-main "Consent Native Cli Daemon Adapter portable tests"
  (command-line))
