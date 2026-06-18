;;; Portable Scheme-callable session management tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program runs under an external R7RS Scheme and exercises the
;;; `(agent session)' REPL verbs (create-session, switch-session /
;;; set-default-session!, current-session, list-sessions, close-session)
;;; through the portable terminal REPL shell, without loading the Emacs host
;;; adapter.  It asserts that switching the default session redirects which
;;; session subsequent forms evaluate in (with per-session definition
;;; isolation -- a fresh session is its own sandbox environment), that the
;;; verbs fail closed without window-session authority and succeed when it is
;;; granted, that they emit Scheme-readable audit records, and that they return
;;; Scheme-readable session records.

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

;; Return the single value of field NAME in tagged list DATUM, or #f.
(define (field datum name)
  (let ((entry (and (pair? datum) (assq name (cdr datum)))))
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

;; Return the evaluated value carried by repl-result RECORD.
(define (result-value record)
  (field (field record 'evaluation-result) 'value))

;; Return #t when EVENTS holds an audit entry of EVENT-KIND for OPERATION.
(define (has-audit? events event-kind operation)
  (let loop ((events events))
    (cond
     ((not (pair? events)) #f)
     ((let ((entry (car events)))
        (and (pair? entry)
             (eq? (kind entry) 'audit-entry)
             (eq? (field entry 'event) event-kind)
             (equal? (field entry 'operation) operation)))
      #t)
     (else (loop (cdr events))))))

;; Window-session authority a REPL caller grants to use the session verbs.
(define session-authority
  '((policy-actions (window-session . allow))))

;; Drive INPUT under the initial session `project-main' with session authority.
(define (drive-authorized input)
  (cli-repl-records-from-string input "project-main" session-authority))

;; Drive INPUT under the initial session with no session authority.
(define (drive-unauthorized input)
  (cli-repl-records-from-string input "project-main"))

;;;; Switching the default session redirects subsequent forms, with isolation

;; `(define marker ...)' lands in whichever session is current when the form
;; runs.  A fresh session is its own sandbox, so the verbs must be imported into
;; each session that uses them; switching back proves the two sessions keep
;; independent environments.
(let ((records
       (drive-authorized
        (string-append
         "(import (agent session))\n"
         "(define marker 1)\n"
         "(create-session 'named '((id work-a)))\n"
         "(switch-session 'work-a)\n"
         "(import (agent session))\n"
         "(define marker 2)\n"
         "marker\n"
         "(switch-session 'project-main)\n"
         "marker\n"))))
  (let ((results (records-of records 'repl-result)))
    (check 'switch-result-count (length results) 9)
    ;; `marker' reads 2 in `work-a' and 1 back in `project-main': switching
    ;; redirected the defines and neither session leaked into the other.
    (check 'switch-defines-in-current-session
           (field (list-ref results 6) 'display) "2")
    (check 'switch-back-keeps-isolation
           (field (list-ref results 8) 'display) "1"))
  (check 'switch-no-conditions (count-of records 'repl-condition) 0))

;; `set-default-session!' is a synonym for `switch-session'.
(let ((records
       (drive-authorized
        (string-append
         "(import (agent session))\n"
         "(define y 7)\n"
         "(create-session 'named '((id work-b)))\n"
         "(set-default-session! 'work-b)\n"
         "(import (agent session))\n"
         "(define y 70)\n"
         "y\n"
         "(set-default-session! 'project-main)\n"
         "y\n"))))
  (let ((results (records-of records 'repl-result)))
    (check 'set-default-redirects (field (list-ref results 6) 'display) "70")
    (check 'set-default-back (field (list-ref results 8) 'display) "7")))

;;;; The verbs return Scheme-readable records and emit audit entries

(let ((records
       (drive-authorized
        (string-append
         "(import (agent session))\n"
         "(create-session 'named '((id inspect-a)))\n"
         "(current-session)\n"
         "(list-sessions)\n"))))
  (let ((results (records-of records 'repl-result)))
    ;; create-session returns a session datum (id inspect-a, status new) and
    ;; emits a Scheme-readable session-lifecycle audit entry in its events.
    (let* ((created-result (list-ref results 1))
           (value (result-value created-result))
           (events (field (field created-result 'evaluation-result) 'events)))
      (check 'create-returns-session-record (kind value) 'session)
      (check 'create-record-id (field value 'id) 'inspect-a)
      (check 'create-record-status (field value 'status) 'new)
      (check-true 'create-emits-capability-request
                  (has-audit? events 'capability-request "create-session"))
      (check-true 'create-emits-lifecycle-audit
                  (has-audit? events 'session-lifecycle 'create)))
    ;; current-session (no switch yet) names the initial project-main session.
    (check 'current-before-switch-id
           (field (result-value (list-ref results 2)) 'id) 'project-main)
    ;; list-sessions returns a list of session records including both sessions.
    (let ((listed (result-value (list-ref results 3))))
      (check-true 'list-sessions-is-list (list? listed))
      (check 'list-sessions-count (length listed) 2))))

;;;; The verbs fail closed without window-session authority

;; Without the grant, create-session denies fail-closed: the form is reported as
;; a recoverable evaluator condition (a Scheme-readable error record) and the
;; session keeps running.
(let ((records
       (drive-unauthorized
        (string-append
         "(import (agent session))\n"
         "(create-session 'named '((id denied-a)))\n"
         "(+ 1 1)\n"))))
  (check 'deny-create-emits-condition (count-of records 'repl-condition) 1)
  (let ((condition (car (records-of records 'repl-condition))))
    (check 'deny-create-phase (field condition 'phase) 'eval))
  ;; The session continues: the trailing arithmetic (the last result, after the
  ;; import result and the denied create) still evaluates.
  (let ((results (records-of records 'repl-result)))
    (check 'deny-session-continues
           (field (list-ref results (- (length results) 1)) 'display) "2")))

;; switch-session is likewise gated and fails closed without authority.
(let ((records
       (drive-unauthorized
        (string-append
         "(import (agent session))\n"
         "(switch-session 'project-main)\n"))))
  (check 'deny-switch-emits-condition (count-of records 'repl-condition) 1))

;;;; close-session retires a session and returns its record

(let ((records
       (drive-authorized
        (string-append
         "(import (agent session))\n"
         "(create-session 'named '((id close-a)))\n"
         "(close-session 'close-a)\n"))))
  (let ((results (records-of records 'repl-result)))
    (let ((closed (result-value (list-ref results 2))))
      (check 'close-returns-session-record (kind closed) 'session)
      (check 'close-record-id (field closed 'id) 'close-a)
      (check 'close-record-status (field closed 'status) 'retired)))
  (check 'close-no-conditions (count-of records 'repl-condition) 0))

(if (> failures 0)
    (error "portable session management tests failed" failures))
