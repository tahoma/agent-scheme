;;; Portable Consent Scheme agent memory tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program exercises the shared `(agent memory)' library directly.  The
;;; Emacs adapter loads the same source, so these checks pin the canonical
;;; memory record stream before host persistence or UI code sees it.

(import (scheme base)
        (agent memory)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

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

(testing-registry-case
 'default-memory-class '(portable agent)
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
  (test-equal 'default-memory-class
             'semantic
             (memory-record-class first))
  (test-equal 'explicit-memory-class
             'procedural
             (memory-record-class second))
  (test-equal 'delete-returns-current-record
             "second"
             (memory-record-field-value deleted 'value #f))
  (test-equal 'deleted-key-is-not-live
             #f
             (memory-store-ref store 'project 'alpha))
  (test-equal 'update-and-delete-append-events
             3
             (length records))
  (test-equal 'tombstone-kind
             'memory-tombstone
             (memory-record-field-value tombstone 'kind #f))
  (test-equal 'tombstone-supersedes-current
             (list (memory-record-id second))
             (memory-record-field-value tombstone 'supersedes #f))
  (test-assert 'first-record-remains-in-stream
             (member-equal? first records))))

;;;; Gated reflection appends insight datums without mutating observations

(testing-registry-case
 'reflection-kind '(portable agent)
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
  (test-equal 'reflection-kind
             'task-reflection
             (memory-record-field-value reflection 'kind #f))
  (test-equal 'reflection-class
             'semantic
             (memory-record-class reflection))
  (test-equal 'reflection-cites-base
             (list (memory-record-id base))
             (memory-record-field-value reflection 'cites #f))
  (test-equal 'reflection-receipt
             'failed
             (memory-record-field-value reflection 'receipt #f))
  (test-equal 'reflection-source
             '(deterministic-loop runner-step-7)
             (memory-record-field-value reflection 'source #f))
  (test-equal 'reflection-appends-only
             2
             (length records))
  (test-assert 'base-observation-remains-in-stream
             (member-equal? base records))))

;;;; Scope-qualified live projection and access recency

(testing-registry-case
 'same-key-project-live-record '(portable agent)
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
  (test-equal 'same-key-project-live-record
             "Project scoped note."
             (memory-record-field-value
          (memory-store-ref store 'project 'shared)
          'value
          #f))
  (test-equal 'same-key-session-live-record
             "Session scoped note."
             (memory-record-field-value
          (memory-store-ref store 'session 'shared)
          'value
          #f))
  (test-equal 'scope-qualified-access-event-kind
             'memory-access
             (memory-record-field-value access 'kind #f))
  (test-equal 'scope-qualified-selected-record-count
             1
             (length (memory-selection-records selection)))
  (test-equal 'scope-qualified-selected-record-scope
             'project
             (memory-record-field-value
          (car (memory-selection-records selection))
          'scope
          #f))
  (test-equal 'scope-qualified-selected-candidate-count
             1
             (count-if
          (lambda (candidate)
            (eq? (memory-record-field-value candidate 'status #f) 'selected))
          candidates))))

;;;; Deterministic retrieval and lower-trust prompt filtering

(testing-registry-case
 'selection-record '(portable agent)
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
  (test-assert 'selection-record
             (memory-selection? selection))
  (test-equal 'access-event-kind
             'memory-access
             (memory-record-field-value access 'kind #f))
  (test-equal 'selected-record-count
             1
             (length (memory-selection-records selection)))
  (test-equal 'selected-record-id
             (memory-record-id public)
             (memory-record-id (car (memory-selection-records selection))))
  (test-equal 'selection-cutoff
             1
             (memory-selection-cutoff selection))
  (test-equal 'public-candidate-status
             'selected
             (memory-record-field-value public-candidate 'status #f))
  (test-equal 'public-candidate-score
             6
             (memory-record-field-value public-candidate 'score #f))
  (test-equal 'public-candidate-subscores
             '((recency 1) (importance 2) (relevance 1))
             (memory-record-field-value public-candidate 'subscores #f))
  (test-equal 'local-candidate-filtered-before-ranking
             'filtered
             (memory-record-field-value local-candidate 'status #f))
  (test-equal 'local-candidate-filter-reason
             'redaction-or-local-only
             (memory-record-field-value local-candidate 'reason #f))
  (test-equal 'local-candidate-not-ranked
             'not-ranked
             (memory-record-field-value local-candidate 'score #f))
  (test-equal 'session-candidate-filtered-by-scope
             'scope-mismatch
             (memory-record-field-value session-candidate 'reason #f))))

;;;; Live projection applies to every store read surface

(testing-registry-case
 'live-projection-record-stream-count '(portable agent)
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
  (test-equal 'live-projection-record-stream-count
             5
             (length (memory-store-records store)))
  (test-equal 'live-projection-deleted-record
             (memory-record-id alpha-new)
             (memory-record-id deleted))
  (test-equal 'live-projection-alpha-ref
             #f
             (memory-store-ref store 'project 'alpha))
  (test-equal 'live-projection-beta-ref
             (memory-record-id beta)
             (memory-record-id (memory-store-ref store 'project 'beta)))
  (test-equal 'live-projection-find-old
             '()
             (memory-store-find store 'project "old alpha"))
  (test-equal 'live-projection-find-new-after-delete
             '()
             (memory-store-find store 'project "new alpha"))
  (test-equal 'live-projection-by-current-tag
             (list (memory-record-id beta))
             (map memory-record-id
              (memory-store-by-tag store 'project 'current)))
  (test-equal 'live-projection-access-event-not-live
             '()
             (map memory-record-id
              (memory-store-by-tag store 'project 'memory-access)))
  (test-equal 'live-projection-recent-only-live
             (list (memory-record-id beta))
             (map memory-record-id recent))
  (test-assert 'live-projection-access-record-is-canonical
             (member-equal? access (memory-store-records store)))
  (test-assert 'live-projection-old-record-remains-canonical
             (member-equal? alpha-old (memory-store-records store)))))

;;;; Deterministic selection ordering, limit, and cutoff receipts

(testing-registry-case
 'selection-limit-selected-list '(portable agent)
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
  (test-equal 'selection-limit-selected-list
             (list (memory-record-id tie-left))
             (map memory-record-id (memory-selection-records selection)))
  (test-equal 'selection-tie-breaks-by-id
             'm-2
             (memory-record-id (car (memory-selection-records selection))))
  (test-equal 'selection-left-status
             'selected
             (memory-record-field-value left-candidate 'status #f))
  (test-equal 'selection-left-score
             5
             (memory-record-field-value left-candidate 'score #f))
  (test-equal 'selection-right-limited
             'not-selected
             (memory-record-field-value right-candidate 'status #f))
  (test-equal 'selection-right-limit-reason
             'below-cutoff-or-limit
             (memory-record-field-value right-candidate 'reason #f))
  (test-equal 'selection-below-cutoff
             'not-selected
             (memory-record-field-value below-candidate 'status #f))
  (test-equal 'selection-below-cutoff-score
             1
             (memory-record-field-value below-candidate 'score #f))
  (test-equal 'selection-below-cutoff-reason
             'below-cutoff-or-limit
             (memory-record-field-value below-candidate 'reason #f))))

;;;; Scope datums and record replacement round-trip canonical memory

(testing-registry-case
 'scope-datum-scope '(portable agent)
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
  (test-equal 'scope-datum-scope
             'project
             (memory-record-field-value scope-datum 'scope #f))
  (test-equal 'scope-datum-storage
             storage
             (memory-record-field-value scope-datum 'storage #f))
  (test-equal 'scope-datum-records-roundtrip
             (list first)
             records)
  (test-equal 'replace-records-return-value
             (list first)
             replaced)
  (test-equal 'replace-records-resets-generated-id
             'm-2
             (memory-record-id second))
  (test-equal 'replace-records-keeps-existing-record
             (memory-record-id first)
             (memory-record-id
          (memory-store-ref roundtrip 'project (memory-record-id first))))
  (test-equal 'session-scope-datum-subject
             'session-1
             (memory-record-field-value session-datum 'session #f))))

;;;; Validation failures and lower-trust redaction filtering

(testing-registry-case
 'invalid-scope '(portable agent)
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
  (test-error 'invalid-scope ((lambda ()
                 (memory-store-add! store
                                    'workspace
                                    'fact
                                    '((value "bad scope"))))))
  (test-error 'invalid-memory-class ((lambda ()
                 (memory-store-add! store
                                    'project
                                    'fact
                                    '((memory-class mystery)
                                      (value "bad class"))))))
  (test-error 'invalid-recent-count ((lambda ()
                 (memory-store-recent store 'project 'one))))
  (test-error 'invalid-selection-limit ((lambda ()
                 (memory-store-select
                  store
                  '(sensitive)
                  '(retrieval-policy (limit one))
                  '(retrieval-context (scope project))))))
  (test-error 'invalid-selection-cutoff ((lambda ()
                 (memory-store-select
                  store
                  '(sensitive)
                  '(retrieval-policy (cutoff high))
                  '(retrieval-context (scope project))))))
  (test-error 'scope-datum-missing-records ((lambda ()
                 (memory-scope-datum-records
                  '(agent-memory (scope project))))))
  (test-equal 'local-trust-allows-sensitive-record
             'selected
             (memory-record-field-value local-candidate 'status #f))
  (test-equal 'remote-trust-filters-nested-redaction
             'redaction-or-local-only
             (memory-record-field-value remote-candidate 'reason #f))
  (test-equal 'public-trust-filters-nested-redaction
             'redaction-or-local-only
             (memory-record-field-value public-candidate 'reason #f))
  (test-equal 'lower-trust-filters-nested-redaction
             'redaction-or-local-only
             (memory-record-field-value lower-candidate 'reason #f))
  (test-equal 'remote-selection-withholds-sensitive-records
             '()
             (memory-selection-records remote-selection))))

(testing-runner-main "Consent Agent Memory portable tests" (command-line))
