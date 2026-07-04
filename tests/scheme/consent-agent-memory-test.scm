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

;; Assert THUNK raises an error.
(define (check-error name thunk)
  (check name
         (guard (condition
                 (else #t))
           (thunk)
           #f)
         #t))

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

;;;; Live projection applies to every store read surface

(let* ((store (consent-make-memory-store))
       (alpha-old
        (memory-store-put! store
                           'project
                           'alpha
                           '((tags (alpha old))
                             (value "old alpha"))))
       (alpha-new
        (memory-store-put! store
                           'project
                           'alpha
                           '((tags (alpha current))
                             (value "new alpha"))))
       (beta
        (memory-store-put! store
                           'project
                           'beta
                           '((tags (beta current))
                             (value "live beta"))))
       (access
        (memory-store-access! store
                              (memory-record-id alpha-new)
                              'project
                              'prompt-build))
       (deleted (memory-store-delete! store 'project 'alpha))
       (recent (memory-store-recent store 'project 10)))
  (check 'live-projection-record-stream-count
         (length (memory-store-records store))
         5)
  (check 'live-projection-deleted-record
         (memory-record-id deleted)
         (memory-record-id alpha-new))
  (check 'live-projection-alpha-ref
         (memory-store-ref store 'project 'alpha)
         #f)
  (check 'live-projection-beta-ref
         (memory-record-id (memory-store-ref store 'project 'beta))
         (memory-record-id beta))
  (check 'live-projection-find-old
         (memory-store-find store 'project "old alpha")
         '())
  (check 'live-projection-find-new-after-delete
         (memory-store-find store 'project "new alpha")
         '())
  (check 'live-projection-by-current-tag
         (map memory-record-id
              (memory-store-by-tag store 'project 'current))
         (list (memory-record-id beta)))
  (check 'live-projection-access-event-not-live
         (map memory-record-id
              (memory-store-by-tag store 'project 'memory-access))
         '())
  (check 'live-projection-recent-only-live
         (map memory-record-id recent)
         (list (memory-record-id beta)))
  (check-true 'live-projection-access-record-is-canonical
              (member-equal? access (memory-store-records store)))
  (check-true 'live-projection-old-record-remains-canonical
              (member-equal? alpha-old (memory-store-records store))))

;;;; Deterministic selection ordering, limit, and cutoff receipts

(let* ((store (consent-make-memory-store))
       (below
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (ranking))
                             (value "below cutoff")
                             (importance 1))))
       (tie-left
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (ranking))
                             (value "tie left")
                             (importance 5))))
       (tie-right
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (ranking))
                             (value "tie right")
                             (importance 5))))
       (selection
        (memory-store-select
         store
         '(not-present)
         '(retrieval-policy
           (weights ((recency 0) (importance 1) (relevance 0)))
           (cutoff 2)
           (limit 1))
         '(retrieval-context
           (scope project)
           (trust local)
           (allowed-scopes (project))
           (logical-clock 10))))
       (below-candidate
        (candidate-for-id selection (memory-record-id below)))
       (left-candidate
        (candidate-for-id selection (memory-record-id tie-left)))
       (right-candidate
        (candidate-for-id selection (memory-record-id tie-right))))
  (check 'selection-limit-selected-list
         (map memory-record-id (memory-selection-records selection))
         (list (memory-record-id tie-left)))
  (check 'selection-tie-breaks-by-id
         (memory-record-id (car (memory-selection-records selection)))
         'm-2)
  (check 'selection-left-status
         (memory-record-field-value left-candidate 'status #f)
         'selected)
  (check 'selection-left-score
         (memory-record-field-value left-candidate 'score #f)
         5)
  (check 'selection-right-limited
         (memory-record-field-value right-candidate 'status #f)
         'not-selected)
  (check 'selection-right-limit-reason
         (memory-record-field-value right-candidate 'reason #f)
         'below-cutoff-or-limit)
  (check 'selection-below-cutoff
         (memory-record-field-value below-candidate 'status #f)
         'not-selected)
  (check 'selection-below-cutoff-score
         (memory-record-field-value below-candidate 'score #f)
         1)
  (check 'selection-below-cutoff-reason
         (memory-record-field-value below-candidate 'reason #f)
         'below-cutoff-or-limit))

;;;; Scope datums and record replacement round-trip canonical memory

(let* ((store (consent-make-memory-store))
       (first
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (roundtrip))
                             (value "roundtrip one"))))
       (storage
        (memory-storage-rules
         'project
         "/private/consent/memory/project.scm"
         "/repo/"
         "/repo/.consent/memory.scm"
         #f))
       (scope-datum
        (memory-scope-datum
         'project
         #f
         storage
         (memory-store-records store)))
       (records (memory-scope-datum-records scope-datum))
       (roundtrip (consent-make-memory-store))
       (replaced (memory-store-replace-records! roundtrip records))
       (second
        (memory-store-add! roundtrip
                           'project
                           'fact
                           '((tags (roundtrip))
                             (value "roundtrip two"))))
       (session-datum
        (memory-scope-datum 'session 'session-1 #f records)))
  (check 'scope-datum-scope
         (memory-record-field-value scope-datum 'scope #f)
         'project)
  (check 'scope-datum-storage
         (memory-record-field-value scope-datum 'storage #f)
         storage)
  (check 'scope-datum-records-roundtrip
         records
         (list first))
  (check 'replace-records-return-value
         replaced
         (list first))
  (check 'replace-records-resets-generated-id
         (memory-record-id second)
         'm-2)
  (check 'replace-records-keeps-existing-record
         (memory-record-id
          (memory-store-ref roundtrip 'project (memory-record-id first)))
         (memory-record-id first))
  (check 'session-scope-datum-subject
         (memory-record-field-value session-datum 'session #f)
         'session-1))

;;;; Validation failures and lower-trust redaction filtering

(let* ((store (consent-make-memory-store))
       (sensitive
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (sensitive))
                             (value (note (redaction (kind secret))))
                             (importance 100))))
       (local-selection
        (memory-store-select
         store
         '(sensitive)
         '(retrieval-policy (cutoff 0))
         '(retrieval-context
           (scope project)
           (trust local)
           (allowed-scopes (project))
           (logical-clock 2))))
       (remote-selection
        (memory-store-select
         store
         '(sensitive)
         '(retrieval-policy (cutoff 0))
         '(retrieval-context
           (scope project)
           (trust remote)
           (allowed-scopes (project))
           (logical-clock 2))))
       (public-selection
        (memory-store-select
         store
         '(sensitive)
         '(retrieval-policy (cutoff 0))
         '(retrieval-context
           (scope project)
           (trust public)
           (allowed-scopes (project))
           (logical-clock 2))))
       (lower-selection
        (memory-store-select
         store
         '(sensitive)
         '(retrieval-policy (cutoff 0))
         '(retrieval-context
           (scope project)
           (trust lower-trust)
           (allowed-scopes (project))
           (logical-clock 2))))
       (local-candidate
        (candidate-for-id local-selection (memory-record-id sensitive)))
       (remote-candidate
        (candidate-for-id remote-selection (memory-record-id sensitive)))
       (public-candidate
        (candidate-for-id public-selection (memory-record-id sensitive)))
       (lower-candidate
        (candidate-for-id lower-selection (memory-record-id sensitive))))
  (check-error 'invalid-scope
               (lambda ()
                 (memory-store-add! store
                                    'workspace
                                    'fact
                                    '((value "bad scope")))))
  (check-error 'invalid-memory-class
               (lambda ()
                 (memory-store-add! store
                                    'project
                                    'fact
                                    '((memory-class mystery)
                                      (value "bad class")))))
  (check-error 'invalid-recent-count
               (lambda ()
                 (memory-store-recent store 'project 'one)))
  (check-error 'invalid-selection-limit
               (lambda ()
                 (memory-store-select
                  store
                  '(sensitive)
                  '(retrieval-policy (limit one))
                  '(retrieval-context (scope project)))))
  (check-error 'invalid-selection-cutoff
               (lambda ()
                 (memory-store-select
                  store
                  '(sensitive)
                  '(retrieval-policy (cutoff high))
                  '(retrieval-context (scope project)))))
  (check-error 'scope-datum-missing-records
               (lambda ()
                 (memory-scope-datum-records
                  '(agent-memory (scope project)))))
  (check 'local-trust-allows-sensitive-record
         (memory-record-field-value local-candidate 'status #f)
         'selected)
  (check 'remote-trust-filters-nested-redaction
         (memory-record-field-value remote-candidate 'reason #f)
         'redaction-or-local-only)
  (check 'public-trust-filters-nested-redaction
         (memory-record-field-value public-candidate 'reason #f)
         'redaction-or-local-only)
  (check 'lower-trust-filters-nested-redaction
         (memory-record-field-value lower-candidate 'reason #f)
         'redaction-or-local-only)
  (check 'remote-selection-withholds-sensitive-records
         (memory-selection-records remote-selection)
         '()))

(if (> failures 0)
    (error "portable agent memory tests failed" failures))
