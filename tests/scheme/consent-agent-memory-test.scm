;;; Portable Consent Scheme agent memory tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program exercises the shared `(agent memory)' library directly.  The
;;; Emacs adapter loads the same source, so these checks pin the canonical
;;; memory record stream before host persistence or UI code sees it.

(import (scheme base)
        (agent memory))

;; Count failed checks so the portable runner reports every mismatch.
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

;; Return #t when VALUE appears in VALUES using equal?.
(define (member-equal? value values)
  (cond
   ((null? values) #f)
   ((equal? value (car values)) #t)
   (else (member-equal? value (cdr values)))))

;; Return the first element satisfying PREDICATE, or #f.
(define (find predicate values)
  (cond
   ((null? values) #f)
   ((predicate (car values)) (car values))
   (else (find predicate (cdr values)))))

;; Return the number of VALUES satisfying PREDICATE.
(define (count-if predicate values)
  (let loop ((rest values) (count 0))
    (cond
     ((null? rest) count)
     ((predicate (car rest)) (loop (cdr rest) (+ count 1)))
     (else (loop (cdr rest) count)))))

;; Return the first memory-selection candidate for ID.
(define (candidate-for-id selection id)
  (find
   (lambda (candidate)
     (equal? (memory-record-field-value candidate 'id #f) id))
   (memory-selection-candidates selection)))

;;;; Memory classes and append-only update/delete projection

(let* ((store (consent-make-memory-store))
       (first
        (memory-store-put! store
                           'project
                           'alpha
                           '((tags (architecture))
                             (value "first"))))
       (second
        (memory-store-put! store
                           'project
                           'alpha
                           '((tags (architecture r7rs))
                             (value "second")
                             (memory-class procedural))))
       (deleted (memory-store-delete! store 'project 'alpha))
       (records (memory-store-records store))
       (tombstone (if (pair? records) (car records) 'missing)))
  (check 'default-memory-class
         (memory-record-class first)
         'semantic)
  (check 'explicit-memory-class
         (memory-record-class second)
         'procedural)
  (check 'delete-returns-current-record
         (memory-record-field-value deleted 'value #f)
         "second")
  (check 'deleted-key-is-not-live
         (memory-store-ref store 'project 'alpha)
         #f)
  (check 'update-and-delete-append-events
         (length records)
         3)
  (check 'tombstone-kind
         (memory-record-field-value tombstone 'kind #f)
         'memory-tombstone)
  (check 'tombstone-supersedes-current
         (memory-record-field-value tombstone 'supersedes #f)
         (list (memory-record-id second)))
  (check-true 'first-record-remains-in-stream
              (member-equal? first records)))

;;;; Gated reflection appends insight datums without mutating observations

(let* ((store (consent-make-memory-store))
       (base
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (failure verifier))
                             (value "Verifier lacked evidence."))))
       (reflection
        (memory-store-reflect! store
                               'project
                               'task-reflection
                               '((value "Collect held-out verifier evidence."))
                               (list (memory-record-id base))
                               'failed
                               'runner-step-7))
       (records (memory-store-records store)))
  (check 'reflection-kind
         (memory-record-field-value reflection 'kind #f)
         'task-reflection)
  (check 'reflection-class
         (memory-record-class reflection)
         'semantic)
  (check 'reflection-cites-base
         (memory-record-field-value reflection 'cites #f)
         (list (memory-record-id base)))
  (check 'reflection-receipt
         (memory-record-field-value reflection 'receipt #f)
         'failed)
  (check 'reflection-source
         (memory-record-field-value reflection 'source #f)
         '(deterministic-loop runner-step-7))
  (check 'reflection-appends-only
         (length records)
         2)
  (check-true 'base-observation-remains-in-stream
              (member-equal? base records)))

;;;; Scope-qualified live projection and access recency

(let* ((store (consent-make-memory-store))
       (project
        (memory-store-put! store
                           'project
                           'shared
                           '((tags (shared))
                             (value "Project scoped note."))))
       (session
        (memory-store-put! store
                           'session
                           'shared
                           '((tags (shared))
                             (value "Session scoped note."))))
       (access
        (memory-store-access! store
                              (memory-record-id project)
                              'project
                              'prompt-build-2))
       (selection
        (memory-store-select
         store
         '(shared)
         '(retrieval-policy
           (weights ((recency 1) (importance 1) (relevance 1)))
           (cutoff 0)
           (limit 1))
         '(retrieval-context
           (scope project)
           (trust local)
           (allowed-scopes (project session))
           (logical-clock 4))))
       (candidates (memory-selection-candidates selection)))
  (check 'same-key-project-live-record
         (memory-record-field-value
          (memory-store-ref store 'project 'shared)
          'value
          #f)
         "Project scoped note.")
  (check 'same-key-session-live-record
         (memory-record-field-value
          (memory-store-ref store 'session 'shared)
          'value
          #f)
         "Session scoped note.")
  (check 'scope-qualified-access-event-kind
         (memory-record-field-value access 'kind #f)
         'memory-access)
  (check 'scope-qualified-selected-record-count
         (length (memory-selection-records selection))
         1)
  (check 'scope-qualified-selected-record-scope
         (memory-record-field-value
          (car (memory-selection-records selection))
          'scope
          #f)
         'project)
  (check 'scope-qualified-selected-candidate-count
         (count-if
          (lambda (candidate)
            (eq? (memory-record-field-value candidate 'status #f) 'selected))
          candidates)
         1))

;;;; Deterministic retrieval and lower-trust prompt filtering

(let* ((store (consent-make-memory-store))
       (public
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (architecture r7rs))
                             (value "Portable Scheme owns memory.")
                             (importance 2))))
       (local
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (architecture secret))
                             (value "Do not disclose.")
                             (local-only #t)
                             (importance 100))))
       (session
        (memory-store-add! store
                           'session
                           'fact
                           '((tags (architecture))
                             (value "Session-local note.")
                             (importance 10))))
       (access
        (memory-store-access! store
                              (memory-record-id public)
                              'project
                              'prompt-build-1))
       (selection
        (memory-store-select
         store
         '(architecture)
         '(retrieval-policy
           (weights ((recency 1) (importance 1) (relevance 3)))
           (cutoff 1)
           (limit 5))
         '(retrieval-context
           (scope project)
           (trust remote)
           (allowed-scopes (project))
           (logical-clock 4))))
       (public-candidate
        (candidate-for-id selection (memory-record-id public)))
       (local-candidate
        (candidate-for-id selection (memory-record-id local)))
       (session-candidate
        (candidate-for-id selection (memory-record-id session))))
  (check-true 'selection-record
              (memory-selection? selection))
  (check 'access-event-kind
         (memory-record-field-value access 'kind #f)
         'memory-access)
  (check 'selected-record-count
         (length (memory-selection-records selection))
         1)
  (check 'selected-record-id
         (memory-record-id (car (memory-selection-records selection)))
         (memory-record-id public))
  (check 'selection-cutoff
         (memory-selection-cutoff selection)
         1)
  (check 'public-candidate-status
         (memory-record-field-value public-candidate 'status #f)
         'selected)
  (check 'public-candidate-score
         (memory-record-field-value public-candidate 'score #f)
         6)
  (check 'public-candidate-subscores
         (memory-record-field-value public-candidate 'subscores #f)
         '((recency 1) (importance 2) (relevance 1)))
  (check 'local-candidate-filtered-before-ranking
         (memory-record-field-value local-candidate 'status #f)
         'filtered)
  (check 'local-candidate-filter-reason
         (memory-record-field-value local-candidate 'reason #f)
         'redaction-or-local-only)
  (check 'local-candidate-not-ranked
         (memory-record-field-value local-candidate 'score #f)
         'not-ranked)
  (check 'session-candidate-filtered-by-scope
         (memory-record-field-value session-candidate 'reason #f)
         'scope-mismatch))

(if (> failures 0)
    (error "portable agent memory tests failed" failures))
