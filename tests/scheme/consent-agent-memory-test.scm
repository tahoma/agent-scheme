;;; Portable Consent Scheme agent memory tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program exercises the shared `(agent memory)' library directly.  The
;;; Emacs adapter loads the same source, so these checks pin the canonical
;;; memory record stream before host persistence or UI code sees it.

(import (scheme base)
        (agent memory)
        (only (agent memory-key)
              call-with-memory-index-key-session
              memory-index-key-bounded-comparison?
              memory-index-key?
              memory-index-key<?
              memory-index-key=?
              memory-prepare-index-key)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; True when the compiled host runner needs the bounded stress ladder.
(define memory-scale-host-run?
  (let ((value (get-environment-variable "TESTING_RUNNER_HOST_RUN")))
    (and value (string=? value "1"))))

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

;; Return the first ranked memory-selection candidate in SCOPE.
(define (candidate-for-scope selection scope)
  (find
   (lambda (candidate)
     (let ((record (memory-record-field-value candidate 'record #f)))
       (and record
            (eq? (memory-record-field-value record 'scope #f) scope))))
   (memory-selection-candidates selection)))

;; Return the first memory-selection candidate whose record has VALUE.
(define (candidate-for-value selection value)
  (find
   (lambda (candidate)
     (let ((record (memory-record-field-value candidate 'record #f)))
       (and record
            (equal? (memory-record-field-value record 'value #f) value))))
   (memory-selection-candidates selection)))

;; Return a canonical record with an explicit shared ID for identity tests.
(define (shared-id-record key value importance sequence)
  (list 'memory
        '(id duplicate-id)
        '(scope project)
        (list 'key key)
        '(kind datum)
        '(memory-class semantic)
        '(tags (duplicate-id))
        (list 'value value)
        '(source ())
        '(confidence unknown)
        (list 'importance importance)
        (list 'created-at sequence)
        (list 'updated-at sequence)))

;; Return a lexically numeric symbol for tie-order selection tests.
(define (ordered-tie-id number)
  (string->symbol
   (string-append "tie-"
                  (cond
                   ((< number 10) "00")
                   ((< number 100) "0")
                  (else ""))
                  (number->string number))))

;; Return a distinct symbol key for persistent store-index scale checks.
(define (symbol-index-scale-key number)
  (string->symbol
   (string-append "symbol-index-" (number->string number))))

;; Exercise symbol-key put, lookup, and update at COUNT live entries.
(define (symbol-index-scale-result count)
  (let ((store (consent-make-memory-store)))
    (let fill ((number 1))
      (if (<= number count)
          (begin
            (memory-store-put!
             store
             'project
             (symbol-index-scale-key number)
             (list (list 'value number)))
            (fill (+ number 1)))))
    (let* ((targets (list 1 (quotient count 2) count))
           (values-for
            (lambda ()
              (map
               (lambda (number)
                 (memory-record-field-value
                  (memory-store-ref
                   store
                   'project
                   (symbol-index-scale-key number))
                  'value
                  #f))
               targets)))
           (initial-values (values-for)))
      (for-each
       (lambda (number)
         (memory-store-put!
          store
          'project
          (symbol-index-scale-key number)
          (list (list 'value (+ count number)))))
       targets)
      (list (length (memory-store-records store))
            initial-values
            (values-for)
            (memory-store-ref store 'project 'absent-symbol-index-key)))))

;; Return a fresh helper-style library-name key for common-index scale checks.
(define (common-index-scale-key number)
  (list 'agent
        'helper
        (string->symbol
         (string-append "common-index-" (number->string number)))))

;; Exercise list-key put, lookup, update, delete, and live projection at COUNT.
(define (common-index-scale-result count)
  (let ((store (consent-make-memory-store)))
    (let fill ((number 1))
      (if (<= number count)
          (begin
            (memory-store-put!
             store
             'project
             (common-index-scale-key number)
             (list (list 'value number)))
            (fill (+ number 1)))))
    (let* ((middle (quotient count 2))
           (targets (list 1 middle count))
           (values-for
            (lambda ()
              (map
               (lambda (number)
                 (let ((record
                        (memory-store-ref
                         store
                         'project
                         (common-index-scale-key number))))
                   (and record
                        (memory-record-field-value record 'value #f))))
               targets)))
           (initial-values (values-for)))
      (for-each
       (lambda (number)
         (memory-store-put!
          store
          'project
          (common-index-scale-key number)
          (list (list 'value (+ count number)))))
       targets)
      (memory-store-delete!
       store 'project (common-index-scale-key count))
      (let ((recent (memory-store-recent store 'project count)))
        (list (length (memory-store-records store))
              initial-values
              (values-for)
              (length recent)
              (memory-record-field-value (car recent) 'value #f))))))

;; Return #t when NEEDLE occurs in HAYSTACK using the simple specification.
(define (reference-string-contains? haystack needle)
  (let ((haystack-length (string-length haystack))
        (needle-length (string-length needle)))
    (let loop ((index 0))
      (cond
       ((> (+ index needle-length) haystack-length) #f)
       ((string=? (substring haystack index (+ index needle-length))
                  needle)
        #t)
       (else (loop (+ index 1)))))))

;; Return all strings of LENGTH over the two-character alphabet Q/Z.
(define (binary-strings-of-length length)
  (if (= length 0)
      (list "")
      (let ((shorter (binary-strings-of-length (- length 1))))
        (append
         (map (lambda (text) (string-append "Q" text)) shorter)
         (map (lambda (text) (string-append "Z" text)) shorter)))))

;; Return all Q/Z strings through MAXIMUM-LENGTH, including the empty string.
(define (binary-strings-through maximum-length)
  (let loop ((length 0) (strings '()))
    (if (> length maximum-length)
        strings
        (loop (+ length 1)
              (append strings (binary-strings-of-length length))))))

;; Return FRAGMENT repeated COUNT times using logarithmic concatenation depth.
(define (repeat-fragment fragment count)
  (let loop ((remaining count) (block fragment) (result ""))
    (if (= remaining 0)
        result
        (loop (quotient remaining 2)
              (string-append block block)
              (if (odd? remaining)
                  (string-append result block)
                  result)))))

;; Return a pair whose cdr is itself and whose car is VALUE.
(define (self-cdr-pair value)
  (let ((pair (cons value #f)))
    (set-cdr! pair pair)
    pair))

;; Return a two-node cdr cycle whose cars are VALUE.
(define (two-period-cdr-pair value)
  (let ((first (cons value #f))
        (second (cons value #f)))
    (set-cdr! first second)
    (set-cdr! second first)
    first))

;; Return a one-node vector cycle.
(define (self-vector-cycle)
  (let ((value (vector #f)))
    (vector-set! value 0 value)
    value))

;; Return a two-node vector cycle.
(define (two-period-vector-cycle)
  (let ((first (vector #f))
        (second (vector #f)))
    (vector-set! first 0 second)
    (vector-set! second 0 first)
    first))

;; Return FIELD's mutable pair in RECORD, or #f.
(define (record-field-pair record name)
  (find
   (lambda (field)
     (and (pair? field) (eq? (car field) name)))
   (cdr record)))

;; Replace RECORD field NAME's value in place.
(define (record-field-set! record name value)
  (let ((field (record-field-pair record name)))
    (if (not field)
        (error "missing memory record field" name))
    (set-car! (cdr field) value)))

;; Return a vector key whose last leaf distinguishes neighboring keys.
(define (late-leaf-key length leaf)
  (let ((value (make-vector length 0)))
    (if (> length 0)
        (vector-set! value (- length 1) leaf))
    value))

;; Reference finite-graph bisimulation used only by the bounded oracle below.
(define (reference-regular-tree-equal? left right)
  (let loop ((pending (list (cons left right))) (seen '()))
    (if (null? pending)
        #t
        (let* ((comparison (car pending))
               (first (car comparison))
               (second (cdr comparison))
               (known?
                (let find-seen ((rest seen))
                  (and
                   (pair? rest)
                   (or
                    (and (eq? first (car (car rest)))
                         (eq? second (cdr (car rest))))
                    (find-seen (cdr rest)))))))
          (cond
           (known? (loop (cdr pending) seen))
           ((and (pair? first) (pair? second))
            (loop
             (cons (cons (car first) (car second))
                   (cons (cons (cdr first) (cdr second))
                         (cdr pending)))
             (cons comparison seen)))
           ((and (vector? first)
                 (vector? second)
                 (= (vector-length first) (vector-length second)))
            (let push ((index 0) (next (cdr pending)))
              (if (= index (vector-length first))
                  (loop next (cons comparison seen))
                  (push
                   (+ index 1)
                   (cons
                    (cons (vector-ref first index)
                          (vector-ref second index))
                    next)))))
           ((or (pair? first)
                (pair? second)
                (vector? first)
                (vector? second))
            #f)
           ((equal? first second)
            (loop (cdr pending) seen))
           (else #f))))))

;; Return one two-pair graph encoded by four base-four edge selectors.
(define (pair-graph-from-code code)
  (let ((first (cons #f #f))
        (second (cons #f #f)))
    (define (choice digit)
      (cond
       ((= digit 0) 0)
       ((= digit 1) 1)
       ((= digit 2) first)
       (else second)))
    (let* ((first-car (modulo code 4))
           (rest-one (quotient code 4))
           (first-cdr (modulo rest-one 4))
           (rest-two (quotient rest-one 4))
           (second-car (modulo rest-two 4))
           (second-cdr (modulo (quotient rest-two 4) 4)))
      (set-car! first (choice first-car))
      (set-cdr! first (choice first-cdr))
      (set-car! second (choice second-car))
      (set-cdr! second (choice second-cdr))
      first)))

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

(testing-registry-case
 'access-recency-is-scope-qualified '(portable agent)
(let* ((store (consent-make-memory-store))
       (project
        (memory-store-put! store
                           'project
                           'shared-access-id
                           '((tags (access-rank))
                             (value "Project access record."))))
       (session
        (memory-store-put! store
                           'session
                           'shared-access-id
                           '((tags (access-rank))
                             (value "Session access record.")))))
  (memory-store-access! store
                        (memory-record-id session)
                        'session
                        'session-prompt)
  (memory-store-access! store
                        (memory-record-id project)
                        'project
                        'project-prompt-1)
  (memory-store-access! store
                        (memory-record-id project)
                        'project
                        'project-prompt-2)
  (let* ((selection
          (memory-store-select
           store
           '(absent)
           '(retrieval-policy
             (weights ((recency 1) (importance 0) (relevance 0)))
             (cutoff 0)
             (limit 2))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project session))
             (logical-clock 6))))
         (project-candidate (candidate-for-scope selection 'project))
         (session-candidate (candidate-for-scope selection 'session))
         (project-subscores
          (memory-record-field-value project-candidate 'subscores '()))
         (session-subscores
          (memory-record-field-value session-candidate 'subscores '())))
    (test-equal 'access-recency-is-scope-qualified
               1/2
               (memory-record-field-value project-subscores 'recency #f))
    (test-equal 'access-recency-keeps-latest-event
               1/8
               (memory-record-field-value session-subscores 'recency #f))
    (test-equal 'access-recency-ranks-latest-first
               'project
               (memory-record-field-value
                (car (memory-selection-records selection))
                'scope
                #f)))))

(testing-registry-case
 'non-symbol-access-ordered-index '(portable agent)
(let* ((store (consent-make-memory-store))
       (project-id (list 'compound 'access 'id))
       (session-id (list 'compound 'access 'id))
       (project
        (memory-store-put! store
                           'project
                           project-id
                           '((tags (ordered))
                             (value "Project compound id."))))
       (session
        (memory-store-put! store
                           'session
                           session-id
                           '((tags (ordered))
                             (value "Session compound id.")))))
  (memory-store-access! store
                        (list 'compound 'access 'id)
                        'session
                        'session-ordered-index)
  (memory-store-access! store
                        (list 'compound 'access 'id)
                        'project
                        'project-ordered-index-1)
  (memory-store-access! store
                        (list 'compound 'access 'id)
                        'project
                        'project-ordered-index-2)
  (let* ((selection
          (memory-store-select
           store
           '()
           '(retrieval-policy
             (weights ((recency 1) (importance 0) (relevance 0)))
             (cutoff 0)
             (limit 2))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project session))
             (logical-clock 6))))
         (project-candidate (candidate-for-scope selection 'project))
         (session-candidate (candidate-for-scope selection 'session))
         (project-subscores
          (memory-record-field-value project-candidate 'subscores '()))
         (session-subscores
          (memory-record-field-value session-candidate 'subscores '())))
    (test-equal 'non-symbol-access-ordered-index
               1/2
               (memory-record-field-value project-subscores 'recency #f))
    (test-equal 'non-symbol-access-ordered-index-scope
               1/8
               (memory-record-field-value session-subscores 'recency #f))
    (test-equal 'non-symbol-access-ordered-index-equal-id
               project-id
               (memory-record-id
                (car (memory-selection-records selection)))))))

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

;;;; Linear prepared text matching and normalized multi-term relevance

(testing-registry-case
 'linear-substring-exhaustive-binary-search '(portable agent)
(let ((samples (binary-strings-through 4)))
  ;; Q and Z occur nowhere in the canonical record wrapper below.  For every
  ;; nonempty binary needle, searching the record therefore has exactly the
  ;; same answer as searching its raw binary payload; the empty needle matches
  ;; both by definition.
  (test-assert
   'linear-substring-exhaustive-binary-search
   (let haystacks ((rest samples))
     (if (null? rest)
         #t
         (let ((store (consent-make-memory-store))
               (haystack (car rest)))
           (memory-store-add!
            store
            'project
            'fact
            (list (list 'tags '(substring-differential))
                  (list 'value haystack)))
           (let queries ((remaining-needles samples))
             (cond
              ((null? remaining-needles) (haystacks (cdr rest)))
              ((eqv? (reference-string-contains?
                       haystack
                       (car remaining-needles))
                     (not (null? (memory-store-find
                                  store
                                  'project
                                  (car remaining-needles)))))
               (queries (cdr remaining-needles)))
              (else #f)))))))))

(testing-registry-case
 'long-near-miss-search '(portable agent)
(let* ((store (consent-make-memory-store))
       (long-value (string-append (make-string 16384 #\a) "b"))
       (periodic-value (repeat-fragment "ab" 8192))
       (near-prefix (make-string 128 #\a))
       (near-match (string-append near-prefix "ab"))
       (near-miss (string-append (make-string 2048 #\a) "c"))
       (periodic-miss
        (string-append (repeat-fragment "ab" 1024) "ac")))
  (memory-store-add! store
                     'project
                     'fact
                     (list (list 'tags '(long-search))
                           (list 'value long-value)))
  (memory-store-add! store
                     'project
                     'fact
                     (list (list 'tags '(periodic-search))
                           (list 'value periodic-value)))
  (test-equal 'long-near-miss-search
             '()
             (memory-store-find store 'project near-miss))
  (test-equal 'periodic-long-near-miss-search
             '()
             (memory-store-find store 'project periodic-miss))
  (test-equal 'long-search-tail-match
             1
             (length (memory-store-find store 'project near-match)))
  (test-equal 'substring-empty-needle
             2
             (length (memory-store-find store 'project "")))))

(testing-registry-case
 'variable-width-string-search '(portable agent)
(let* ((store (consent-make-memory-store))
       (wide-tail (make-string 16384 #\λ))
       (value
        (string-append
         "variable-width-head-" wide-tail "-variable-width-tail")))
  (memory-store-add!
   store
   'project
   'fact
   (list (list 'tags '(variable-width-search))
         (list 'value value)))
  (test-equal 'variable-width-head-match
              1
              (length
               (memory-store-find store 'project "variable-width-head")))
  (test-equal 'variable-width-tail-match
              1
              (length
               (memory-store-find store 'project "variable-width-tail")))
  (test-equal 'variable-width-near-miss
              '()
              (memory-store-find store 'project "λQ"))))

(testing-registry-case
 'multi-term-relevance-count '(portable agent)
(let* ((store (consent-make-memory-store))
       (target
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (portable))
                             (value "needle-one and needle-two"))))
       (other
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (other))
                             (value "unrelated text"))))
       (selection
        (memory-store-select
         store
         '(portable "needle-one" needle-two "needle-one" "missing")
         '(retrieval-policy
           (weights ((recency 0) (importance 0) (relevance 1)))
           (cutoff 0)
           (limit 2))
         '(retrieval-context
           (scope project)
           (trust local)
           (allowed-scopes (project))
           (logical-clock 2))))
       (target-candidate
        (candidate-for-id selection (memory-record-id target)))
       (other-candidate
        (candidate-for-id selection (memory-record-id other)))
       (target-subscores
        (memory-record-field-value target-candidate 'subscores '()))
       (other-subscores
        (memory-record-field-value other-candidate 'subscores '())))
  (test-equal 'multi-term-relevance-count
             4
             (memory-record-field-value target-subscores 'relevance #f))
  (test-equal 'multi-term-keeps-duplicate-terms
             4
             (memory-record-field-value target-candidate 'score #f))
  (test-equal 'multi-term-nonmatching-record-score
             0
             (memory-record-field-value other-subscores 'relevance #f))))

(testing-registry-case
 'multi-pattern-overlap-relevance '(portable agent)
(let* ((store (consent-make-memory-store))
       (first
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (overlap-first))
                             (value "ushers"))))
       (second
        (memory-store-add! store
                           'project
                           'fact
                           '((tags (overlap-second))
                             (value "ushers"))))
       (selection
        (memory-store-select
         store
         '("he" "she" "hers" "his" "she" "")
         '(retrieval-policy
           (weights ((recency 0) (importance 0) (relevance 1)))
           (cutoff 0)
           (limit 2))
         '(retrieval-context
           (scope project)
           (trust local)
           (allowed-scopes (project))
           (logical-clock 2))))
       (first-candidate
        (candidate-for-id selection (memory-record-id first)))
       (second-candidate
        (candidate-for-id selection (memory-record-id second))))
  ;; "she" reaches "he" through a failure/output link, "hers" overlaps it,
  ;; the duplicate "she" retains multiplicity, and the empty term matches.
  (test-equal
   'multi-pattern-overlap-first-score
   5
   (memory-record-field-value first-candidate 'score #f))
  (test-equal
   'multi-pattern-overlap-second-generation
   5
   (memory-record-field-value second-candidate 'score #f))))

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

(testing-registry-case
 'live-projection-symbol-scale '(portable agent)
(let ((store (consent-make-memory-store))
      (record-count 64))
  (let fill ((number 1))
    (if (<= number record-count)
        (begin
          (memory-store-put! store
                             'project
                             (ordered-tie-id number)
                             '((tags (symbol-scale))
                               (value "initial")))
          (fill (+ number 1)))))
  (let update ((number 1))
    (if (<= number record-count)
        (begin
          (memory-store-put! store
                             'project
                             (ordered-tie-id number)
                             '((tags (symbol-scale current))
                               (value "updated")))
          (update (+ number 1)))))
  (let delete ((number 8))
    (if (<= number record-count)
        (begin
          (memory-store-delete! store 'project (ordered-tie-id number))
          (delete (+ number 8)))))
  (memory-store-access! store
                        (ordered-tie-id 63)
                        'project
                        'live-projection-symbol-scale)
  (let* ((recent (memory-store-recent store 'project record-count))
         (expected
          (let loop ((number 1) (ids '()))
            (cond
             ((> number record-count) ids)
             ((= (modulo number 8) 0)
              (loop (+ number 1) ids))
             (else
              (loop (+ number 1)
                    (cons (ordered-tie-id number) ids)))))))
    (test-equal 'live-projection-symbol-scale
               expected
               (map memory-record-id recent))
    (test-equal 'live-projection-symbol-newest-value
               "updated"
               (memory-record-field-value (car recent) 'value #f))
    (test-equal 'live-projection-symbol-tombstones-shadow
               #f
               (memory-store-ref store 'project (ordered-tie-id 64)))
    (test-equal 'live-projection-symbol-access-events-excluded
               (- record-count 8)
               (length recent)))))

(testing-registry-case
 'persistent-symbol-store-index-scale '(portable agent)
(if memory-scale-host-run?
    ;; Direct R7RS hosts exercise the full 64/256/1024 ladder natively.  The
    ;; compiled host-run path interprets this test, so retain three increasing
    ;; index sizes there without adding tens of seconds to every compiled run.
    (begin
      (test-equal 'persistent-symbol-store-index-scale-host-run-8
                  '(11 (1 4 8) (9 12 16) #f)
                  (symbol-index-scale-result 8))
      (test-equal 'persistent-symbol-store-index-scale-host-run-32
                  '(35 (1 16 32) (33 48 64) #f)
                  (symbol-index-scale-result 32))
      (test-equal 'persistent-symbol-store-index-scale-host-run-128
                  '(131 (1 64 128) (129 192 256) #f)
                  (symbol-index-scale-result 128)))
    (begin
      (test-equal 'persistent-symbol-store-index-scale-64
                  '(67 (1 32 64) (65 96 128) #f)
                  (symbol-index-scale-result 64))
      (test-equal 'persistent-symbol-store-index-scale-256
                  '(259 (1 128 256) (257 384 512) #f)
                  (symbol-index-scale-result 256))
      (test-equal 'persistent-symbol-store-index-scale-1024
                  '(1027 (1 512 1024) (1025 1536 2048) #f)
                  (symbol-index-scale-result 1024)))))

(testing-registry-case
 'persistent-common-store-index-scale '(portable agent)
(if memory-scale-host-run?
    (begin
      (test-equal 'persistent-common-store-index-scale-host-run-8
                  '(12 (1 4 8) (9 12 #f) 7 12)
                  (common-index-scale-result 8))
      (test-equal 'persistent-common-store-index-scale-host-run-32
                  '(36 (1 16 32) (33 48 #f) 31 48)
                  (common-index-scale-result 32))
      (test-equal 'persistent-common-store-index-scale-host-run-128
                  '(132 (1 64 128) (129 192 #f) 127 192)
                  (common-index-scale-result 128)))
    (begin
      (test-equal 'persistent-common-store-index-scale-64
                  '(68 (1 32 64) (65 96 #f) 63 96)
                  (common-index-scale-result 64))
      (test-equal 'persistent-common-store-index-scale-256
                  '(260 (1 128 256) (257 384 #f) 255 384)
                  (common-index-scale-result 256))
      (test-equal 'persistent-common-store-index-scale-1024
                  '(1028 (1 512 1024) (1025 1536 #f) 1023 1536)
                  (common-index-scale-result 1024)))))

(testing-registry-case
 'common-key-collisions-live-and-rebuild '(portable agent)
(let* ((store (consent-make-memory-store))
       (integer-key (list 'agent 'helper 1))
       (equal-integer-key (list 'agent 'helper 1))
       (symbol-part-key
        (list 'agent 'helper (string->symbol "1")))
       (prefix-key (list 'agent 'helper))
       (caller-string (string-copy "agent-helper-1"))
       (symbol-key (string->symbol "agent-helper-1"))
       (integer-old
        (memory-store-put!
         store 'project integer-key '((value "integer old"))))
       (integer-new
        (memory-store-put!
         store 'project equal-integer-key '((value "integer new"))))
       (symbol-part
        (memory-store-put!
         store 'project symbol-part-key '((value "symbol part"))))
       (prefix
        (memory-store-put!
         store 'project prefix-key '((value "prefix"))))
       (string-record
        (memory-store-put!
         store 'project caller-string '((value "string"))))
       (symbol-record
        (memory-store-put!
         store 'project symbol-key '((value "symbol"))))
       (live-before-delete
        (memory-store-recent store 'project 10)))
  (test-assert 'equal-list-keys-have-distinct-spines
               (not (eq? integer-key equal-integer-key)))
  (test-equal 'equal-list-key-update-keeps-first-id
             (memory-record-id integer-old)
             (memory-record-id integer-new))
  (test-equal 'equal-list-key-lookup-finds-update
             "integer new"
             (memory-record-field-value
              (memory-store-ref store 'project (list 'agent 'helper 1))
              'value
              #f))
  (test-equal 'live-list-projection-groups-equal-spines
             5
             (length live-before-delete))
  (test-equal 'integer-and-symbol-list-parts-do-not-collide
             (memory-record-id symbol-part)
             (memory-record-id
              (memory-store-ref store 'project symbol-part-key)))
  (test-equal 'list-prefix-does-not-collide
             (memory-record-id prefix)
             (memory-record-id
              (memory-store-ref store 'project prefix-key)))
  (test-equal 'string-and-symbol-keys-do-not-collide
             (list (memory-record-id string-record)
                   (memory-record-id symbol-record))
             (list
              (memory-record-id
               (memory-store-ref store 'project "agent-helper-1"))
              (memory-record-id
               (memory-store-ref store 'project symbol-key))))
  (let ((deleted
         (memory-store-delete!
          store 'project (list 'agent 'helper 1))))
    (test-equal 'equal-list-key-delete-returns-update
               (memory-record-id integer-new)
               (memory-record-id deleted)))
  (test-equal 'equal-list-key-tombstone-shadows-history
             #f
             (memory-store-ref store 'project integer-key))
  ;; The index owns a string copy, so mutating the caller's record alias cannot
  ;; corrupt tree ordering.  Explicit replacement rebuilds from the edit.
  (string-set! caller-string 0 #\X)
  (test-assert 'string-index-keeps-private-append-time-copy
               (eq? string-record
                    (memory-store-ref store 'project "agent-helper-1")))
  (test-equal 'string-alias-mutation-does-not-retarget-index
             #f
             (memory-store-ref store 'project "Xgent-helper-1"))
  (let* ((records (memory-store-records store))
         (rebuilt (consent-make-memory-store)))
    (memory-store-replace-records! rebuilt records)
    (test-equal 'common-index-rebuild-preserves-list-tombstone
               #f
               (memory-store-ref rebuilt 'project integer-key))
    (test-assert 'common-index-rebuild-preserves-typed-list-collision
                 (eq? symbol-part
                      (memory-store-ref rebuilt 'project symbol-part-key)))
    (let ((old-key-record
           (memory-store-ref rebuilt 'project "agent-helper-1"))
          (edited-key-record
           (memory-store-ref rebuilt 'project "Xgent-helper-1")))
      (test-equal 'common-index-rebuild-uses-edited-string-key
                 (list #f (memory-record-id string-record))
                 (list old-key-record
                       (memory-record-id edited-key-record)))))))

(testing-registry-case
 'common-key-access-recency '(portable agent)
(let* ((store (consent-make-memory-store))
       (integer-key (list 'agent 'helper 1))
       (symbol-key (list 'agent 'helper (string->symbol "1")))
       (integer-record
        (memory-store-put!
         store 'project integer-key '((value "integer key"))))
       (symbol-record
        (memory-store-put!
         store 'project symbol-key '((value "symbol key")))))
  (memory-store-access!
   store (list 'agent 'helper 1) 'project 'common-key-access)
  (let* ((selection
          (memory-store-select
           store
           '()
           '(retrieval-policy (cutoff 0) (limit 2))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project))
             (logical-clock 3))))
         (integer-candidate
          (candidate-for-id selection (memory-record-id integer-record)))
         (symbol-candidate
          (candidate-for-id selection (memory-record-id symbol-record)))
         (integer-subscores
          (memory-record-field-value integer-candidate 'subscores '()))
         (symbol-subscores
          (memory-record-field-value symbol-candidate 'subscores '())))
    (test-equal 'equal-list-access-event-promotes-target
               (memory-record-id integer-record)
               (memory-record-id (car (memory-selection-records selection))))
    (test-equal 'equal-list-access-event-has-latest-recency
               1
               (memory-record-field-value integer-subscores 'recency #f))
    (test-equal 'typed-list-collision-does-not-share-access
               1/2
               (memory-record-field-value symbol-subscores 'recency #f)))))

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

(testing-registry-case
 'selection-mergesort-reverse-ties '(portable agent)
(let ((store (consent-make-memory-store))
      (candidate-count 64))
  (let fill ((number 1))
    (if (<= number candidate-count)
        (begin
          (memory-store-put! store
                             'project
                             (ordered-tie-id number)
                             '((tags (sort-tie))
                               (value "Equal-score candidate.")))
          (fill (+ number 1)))))
  (let access ((number 1))
    (if (<= number candidate-count)
        (begin
          (memory-store-access! store
                                (ordered-tie-id number)
                                'project
                                'symbol-fast-path-scale)
          (access (+ number 1)))))
  (let* ((selection
          (memory-store-select
           store
           '()
           (list 'retrieval-policy
                 '(weights ((recency 0) (importance 0) (relevance 0)))
                 '(cutoff 0)
                 (list 'limit candidate-count))
           (list 'retrieval-context
                 '(scope project)
                 '(trust local)
                 '(allowed-scopes (project))
                 (list 'logical-clock (* candidate-count 2)))))
         (selected-ids
          (map memory-record-id (memory-selection-records selection)))
         (latest-candidate
          (candidate-for-id selection (ordered-tie-id candidate-count)))
         (previous-candidate
          (candidate-for-id selection
                            (ordered-tie-id (- candidate-count 1))))
         (latest-subscores
          (memory-record-field-value latest-candidate 'subscores '()))
         (previous-subscores
          (memory-record-field-value previous-candidate 'subscores '()))
         (expected-ids
          (let loop ((number candidate-count) (ids '()))
            (if (= number 0)
                ids
                (loop (- number 1)
                      (cons (ordered-tie-id number) ids))))))
    (test-equal 'selection-mergesort-reverse-ties
               expected-ids
               selected-ids)
    (test-equal 'selection-mergesort-keeps-all-ties
               candidate-count
               (length selected-ids))
    (test-equal 'symbol-access-index-finds-latest
               1
               (memory-record-field-value latest-subscores 'recency #f))
    (test-equal 'symbol-access-index-finds-adjacent
               1/2
               (memory-record-field-value previous-subscores 'recency #f)))))

(testing-registry-case
 'selection-duplicate-id-ordinal-identity '(portable agent)
(let* ((store (consent-make-memory-store))
       (high (shared-id-record 'high-key "high" 10 100))
       (low (shared-id-record 'low-key "low" 1 50))
       (middle (shared-id-record 'middle-key "middle" 5 1)))
  (memory-store-replace-records! store (list middle low high))
  (let* ((selection
          (memory-store-select
           store
           '()
           '(retrieval-policy
             (weights ((recency 0) (importance 1) (relevance 0)))
             (cutoff 0)
             (limit 2))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project))
             (logical-clock 3))))
         (high-candidate (candidate-for-value selection "high"))
         (low-candidate (candidate-for-value selection "low"))
         (middle-candidate (candidate-for-value selection "middle")))
    (test-equal 'selection-duplicate-id-ordinal-identity
               '("high" "middle")
               (map
                (lambda (record)
                  (memory-record-field-value record 'value #f))
                (memory-selection-records selection)))
    (test-equal 'selection-duplicate-id-public-score-order
               '(duplicate-id duplicate-id)
               (map memory-record-id (memory-selection-records selection)))
    (test-equal 'selection-duplicate-id-high-selected
               'selected
               (memory-record-field-value high-candidate 'status #f))
    (test-equal 'selection-duplicate-id-middle-selected
               'selected
               (memory-record-field-value middle-candidate 'status #f))
    (test-equal 'selection-duplicate-id-low-not-selected
               'not-selected
               (memory-record-field-value low-candidate 'status #f))
    (test-equal 'selection-final-candidate-projection-order
               '("middle" "low" "high")
               (map
                (lambda (candidate)
                  (memory-record-field-value
                   (memory-record-field-value candidate 'record #f)
                   'value
                   #f))
                (memory-selection-candidates selection)))
    (test-equal 'recent-order-uses-stream-position-not-timestamp
                '("middle" "low" "high")
                (map
                 (lambda (record)
                   (memory-record-field-value record 'value #f))
                 (memory-store-recent store 'project 3))))
  (memory-store-access! store 'duplicate-id 'project 'duplicate-access)
  (let ((access-selection
         (memory-store-select
          store
          '()
          '(retrieval-policy
            (weights ((recency 1) (importance 0) (relevance 0)))
            (cutoff 0)
            (limit 3))
          '(retrieval-context
            (scope project)
            (trust local)
            (allowed-scopes (project))
            (logical-clock 101)))))
    (test-equal 'duplicate-id-access-updates-every-live-candidate
                '(1 1 1)
                (map
                 (lambda (candidate)
                   (memory-record-field-value
                    (memory-record-field-value candidate 'subscores '())
                    'recency
                    #f))
                 (memory-selection-candidates access-selection)))
    (test-equal 'duplicate-id-access-keeps-stream-tie-order
                '("middle" "low" "high")
                (map
                 (lambda (record)
                   (memory-record-field-value record 'value #f))
                 (memory-selection-records access-selection))))))

(testing-registry-case
 'replace-access-before-live-record '(portable agent)
(let* ((source (consent-make-memory-store))
       (live
        (memory-store-put!
         source 'project 'future-id '((value "future live"))))
       (access
        (memory-store-access!
         source 'future-id 'project 'future-access))
       (rebuilt (consent-make-memory-store)))
  (record-field-set! live 'created-at 1)
  (record-field-set! live 'updated-at 1)
  (record-field-set! access 'created-at 99)
  (record-field-set! access 'updated-at 99)
  ;; RECORDS are newest first, so replay observes ACCESS before LIVE even
  ;; though their public timestamps deliberately disagree with stream order.
  (memory-store-replace-records! rebuilt (list live access))
  (let* ((selection
          (memory-store-select
           rebuilt
           '()
           '(retrieval-policy
             (weights ((recency 1) (importance 0) (relevance 0)))
             (cutoff 0)
             (limit 1))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project))
             (logical-clock 100))))
         (candidate (candidate-for-id selection 'future-id))
         (subscores
          (memory-record-field-value candidate 'subscores '())))
    (test-equal 'replace-access-before-live-record
                1/2
                (memory-record-field-value subscores 'recency #f))
    (test-assert 'replace-access-before-live-preserves-record-identity
                 (eq? live (car (memory-selection-records selection))))
    (test-equal 'replace-live-order-ignores-public-timestamps
                (list live)
                (memory-store-recent rebuilt 'project 1)))))

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

(testing-registry-case
 'replace-records-rebuilds-symbol-index '(portable agent)
(let* ((source (consent-make-memory-store))
       (alpha-old
        (memory-store-put! source
                           'project
                           'alpha
                           '((value "old alpha"))))
       (access
        (memory-store-access! source 'alpha 'project 'index-rebuild))
       (alpha-new
        (memory-store-put! source
                           'project
                           'alpha
                           '((value "new alpha"))))
       (doomed
        (memory-store-put! source
                           'project
                           'doomed
                           '((value "delete me"))))
       (deleted (memory-store-delete! source 'project 'doomed))
       (records (memory-store-records source))
       (rebuilt (consent-make-memory-store))
       (orphaned-tombstone (consent-make-memory-store)))
  (memory-store-replace-records! rebuilt records)
  (memory-store-replace-records! orphaned-tombstone (list (car records)))
  (test-equal 'replace-records-keeps-newest-symbol-record
             (memory-record-id alpha-new)
             (memory-record-id
              (memory-store-ref rebuilt 'project 'alpha)))
  (test-equal 'replace-records-keeps-newest-symbol-value
             "new alpha"
             (memory-record-field-value
              (memory-store-ref rebuilt 'project 'alpha)
              'value
              #f))
  (test-equal 'replace-records-tombstone-deletes-index-entry
             #f
             (memory-store-ref rebuilt 'project 'doomed))
  (test-equal 'replace-records-orphaned-tombstone-deletes-absent-entry
             #f
             (memory-store-ref orphaned-tombstone 'project 'doomed))
  (test-equal 'replace-records-access-does-not-enter-index
             #f
             (memory-store-ref
              rebuilt
              'project
              (memory-record-field-value access 'key #f)))
  (test-equal 'replace-records-preserves-canonical-stream
             records
             (memory-store-records rebuilt))
  (test-error
   'replace-records-invalid-rebuild-rolls-back
   ((lambda ()
      (memory-store-replace-records!
       rebuilt (cons '(malformed-memory-record) records)))))
  (test-equal 'replace-records-rollback-preserves-canonical-stream
              records
              (memory-store-records rebuilt))
  (test-equal 'replace-records-rollback-preserves-live-index
              "new alpha"
              (memory-record-field-value
               (memory-store-ref rebuilt 'project 'alpha)
               'value
               #f))
  (test-equal 'replace-records-preserves-deleted-record-result
             (memory-record-id doomed)
             (memory-record-id deleted))
  (test-equal 'replace-records-rebuilds-next-id-with-index
             'm-6
             (memory-record-id
              (memory-store-add!
               rebuilt
               'project
               'fact
               '((value "after rebuild")))))
  (test-assert 'replace-records-old-symbol-record-stays-canonical
               (member-equal? alpha-old records))))

(testing-registry-case
 'memory-field-spines-fail-closed '(portable agent memory safety)
(let* ((store (consent-make-memory-store))
       (stable
        (memory-store-put!
         store 'project 'stable '((value "stable value"))))
       (before (memory-store-records store))
       (cyclic-payload (list '(value "cyclic payload")))
       (improper-payload (cons '(value "improper payload") 'tail))
       (cyclic-record (map (lambda (field) field) stable))
       (cyclic-tail
        (let loop ((rest cyclic-record))
          (if (pair? (cdr rest)) (loop (cdr rest)) rest)))
       (improper-record
        (cons 'memory
              (cons '(id improper-record)
                    (cons '(scope project) 'tail)))))
  (set-cdr! cyclic-payload cyclic-payload)
  (set-cdr! cyclic-tail (cdr cyclic-record))
  (test-error
   'put-rejects-cyclic-field-spine
   ((lambda ()
      (memory-store-put! store 'project 'cyclic cyclic-payload))))
  (test-error
   'add-rejects-improper-field-spine
   ((lambda ()
      (memory-store-add! store 'project 'fact improper-payload))))
  (test-error
   'reflect-rejects-cyclic-field-spine
   ((lambda ()
      (memory-store-reflect!
       store 'project 'reflection cyclic-payload '() 'receipt 'loop))))
  (test-error
   'replace-rejects-cyclic-record-spine
   ((lambda ()
      (memory-store-replace-records! store (list cyclic-record)))))
  (test-error
   'replace-rejects-improper-record-spine
   ((lambda ()
      (memory-store-replace-records! store (list improper-record)))))
  (test-assert 'field-spine-rejections-preserve-state-root
               (eq? before (memory-store-records store)))
  (test-assert 'field-spine-rejections-preserve-live-index
               (eq? stable (memory-store-ref store 'project 'stable)))))

(testing-registry-case
 'mutated-live-field-spine-fails-closed '(portable agent memory safety)
(let* ((store (consent-make-memory-store))
       (record
        (memory-store-put!
         store 'project 'mutated-cycle '((value "before cycle"))))
       (tail
        (let loop ((rest record))
          (if (pair? (cdr rest)) (loop (cdr rest)) rest))))
  (set-cdr! tail (cdr record))
  (test-error
   'record-field-read-rejects-mutated-cycle
   ((lambda () (memory-record-field-value record 'value #f))))
  (test-error
   'selection-rejects-mutated-live-cycle
   ((lambda ()
      (memory-store-select
       store
       'mutated-cycle
       '(retrieval-policy (cutoff 0) (limit 1))
       '(retrieval-context
         (scope project)
         (trust local)
         (allowed-scopes (project))
         (logical-clock 1))))))))

(testing-registry-case
 'non-symbol-store-key-ordered-index '(portable agent)
(let* ((store (consent-make-memory-store))
       (first-key (list 'compound (list 'memory 'key)))
       (second-key (list 'compound (list 'memory 'key)))
       (lookup-key (list 'compound (list 'memory 'key)))
       (delete-key (list 'compound (list 'memory 'key)))
       (first
        (memory-store-put! store
                           'project
                           first-key
                           '((value "first compound value"))))
       (second
        (memory-store-put! store
                           'project
                           second-key
                           '((value "second compound value"))))
       (symbol-record
        (memory-store-put! store
                           'project
                           'symbol-neighbor
                           '((value "symbol value"))))
       (looked-up (memory-store-ref store 'project lookup-key))
       (deleted (memory-store-delete! store 'project delete-key)))
  (test-assert 'non-symbol-store-keys-use-exact-equal-semantics
               (equal? first-key lookup-key))
  (test-equal 'non-symbol-store-key-uses-canonical-index
             "second compound value"
             (memory-record-field-value looked-up 'value #f))
  (test-equal 'non-symbol-store-key-update-keeps-first-id
             (memory-record-id first)
             (memory-record-id second))
  (test-equal 'non-symbol-store-key-delete-returns-current
             (memory-record-id second)
             (memory-record-id deleted))
  (test-equal 'non-symbol-store-key-tombstone-shadows-history
             #f
             (memory-store-ref
              store
              'project
              (list 'compound (list 'memory 'key))))
  (test-equal 'non-symbol-store-index-does-not-disturb-symbol-neighbor
             (memory-record-id symbol-record)
             (memory-record-id
              (memory-store-ref store 'project 'symbol-neighbor)))))

(testing-registry-case
 'record-alias-mutation-requires-replacement '(portable agent)
(let* ((store (consent-make-memory-store))
       (record
        (memory-store-put! store
                           'project
                           'alias-original
                           '((value "alias mutation"))))
       (key-field
        (find
         (lambda (field)
           (and (pair? field) (eq? (car field) 'key)))
         (cdr record))))
  ;; Direct field mutation is outside the append-only store contract.  The
  ;; append-time key remains indexed until the edited stream is reinstalled.
  (set-car! (cdr key-field) 'alias-retargeted)
  (test-assert 'record-alias-mutation-keeps-append-time-key
               (eq? record
                    (memory-store-ref store 'project 'alias-original)))
  (test-equal 'record-alias-mutation-does-not-retarget-index
             #f
             (memory-store-ref store 'project 'alias-retargeted))
  (memory-store-replace-records! store (memory-store-records store))
  (test-equal 'record-alias-replacement-removes-old-key
             #f
             (memory-store-ref store 'project 'alias-original))
  (test-assert 'record-alias-replacement-rebuilds-edited-key
               (eq? record
                    (memory-store-ref store 'project 'alias-retargeted)))))

(testing-registry-case
 'query-results-preserve-canonical-record-identity
 '(portable agent memory boundary identity)
(let* ((store (consent-make-memory-store))
       (record
        (memory-store-put!
         store
         'project
         'identity-record
         '((tags (identity-query))
           (value "identity payload"))))
       (selection
        (memory-store-select
         store
         '(identity-query)
         '(retrieval-policy (cutoff 0) (limit 1))
         '(retrieval-context
           (scope project)
           (allowed-scopes (project))
           (logical-clock 1)))))
  (test-assert
   'find-preserves-canonical-record-identity
   (eq? record
        (car (memory-store-find store 'project "identity payload"))))
  (test-assert
   'by-tag-preserves-canonical-record-identity
   (eq? record
        (car (memory-store-by-tag store 'project 'identity-query))))
  (test-assert
   'recent-preserves-canonical-record-identity
   (eq? record (car (memory-store-recent store 'project 1))))
  (test-assert
   'select-preserves-canonical-record-identity
   (eq? record (car (memory-selection-records selection))))))

(testing-registry-case
 'record-identity-fields-use-append-snapshot
 '(portable agent memory mutation)
(let* ((store (consent-make-memory-store))
       (record
        (memory-store-put!
         store
         'project
         'snapshot-key
         '((tags (snapshot-tag)) (value "snapshot identity"))))
       (original-id (memory-record-id record)))
  (record-field-set! record 'scope 'session)
  (record-field-set! record 'id 'mutated-id)
  (record-field-set! record 'kind 'mutated-kind)
  (record-field-set! record 'tags '(mutated-tag))
  (memory-store-access! store original-id 'project 'snapshot-access)
  (let* ((recent (memory-store-recent store 'project 10))
         (tagged (memory-store-by-tag store 'project 'snapshot-tag))
         (selection
          (memory-store-select
           store
           '(snapshot-key snapshot-tag datum)
           '(retrieval-policy
             (weights ((recency 0) (importance 0) (relevance 1)))
             (cutoff 0)
             (limit 1))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project))
             (logical-clock 2))))
         (candidate (candidate-for-value selection "snapshot identity"))
         (subscores
          (memory-record-field-value candidate 'subscores '())))
    (test-equal 'mutated-scope-keeps-append-time-projection
                (list record)
                recent)
    (test-equal 'mutated-tags-keep-append-time-projection
                (list record)
                tagged)
    (test-equal 'mutated-key-kind-tags-use-detached-relevance
                3
                (memory-record-field-value subscores 'relevance #f)))
  (memory-store-replace-records! store (memory-store-records store))
  (test-equal 'replace-accepts-mutated-scope-and-tags
              (list record)
              (memory-store-by-tag store 'session 'mutated-tag))
  (test-equal 'replace-removes-old-scope-projection
              '()
              (memory-store-recent store 'project 10))))

(testing-registry-case
 'mutated-sensitive-content-fails-closed '(portable agent memory security)
(let* ((store (consent-make-memory-store))
       (record
        (memory-store-put!
         store
         'project
         'mutable-security
         '((tags (mutable-security)) (value "initially public")))))
  (record-field-set!
   record 'value '(note (redaction (kind secret))))
  (let* ((selection
          (memory-store-select
           store
           '(mutable-security)
           '(retrieval-policy (cutoff 0) (limit 1))
           '(retrieval-context
             (scope project)
             (trust remote)
             (allowed-scopes (project))
             (logical-clock 1))))
         (candidate (candidate-for-id selection (memory-record-id record))))
    (test-equal 'mutated-sensitive-content-fails-closed
                '()
                (memory-selection-records selection))
    (test-equal 'mutated-sensitive-candidate-is-filtered
                'redaction-or-local-only
                (memory-record-field-value candidate 'reason #f)))))

(testing-registry-case
 'text-query-uses-canonical-datum-spelling
 '(portable agent memory boundary writer)
(let* ((store (consent-make-memory-store))
       (record
        (memory-store-put!
         store
         'project
         'canonical-text
         (list
          '(tags (canonical-text))
          (list
           'value
           (list 1.0 0.1 1e20 #\space (bytevector 0 255))))))
       (selection
        (memory-store-select
         store
         '("1.0" "0.1" "1e+20" "#\\space" "#u8(0 255)")
         '(retrieval-policy
           (weights ((recency 0) (importance 0) (relevance 1)))
           (cutoff 5)
           (limit 1))
         '(retrieval-context
           (scope project)
           (allowed-scopes (project))
           (logical-clock 1)))))
  (test-assert
   'find-matches-canonical-inexact-spelling
   (eq? record (car (memory-store-find store 'project "1.0"))))
  (test-assert
   'find-matches-canonical-fraction-spelling
   (eq? record (car (memory-store-find store 'project "0.1"))))
  (test-assert
   'find-matches-canonical-exponent-spelling
   (eq? record (car (memory-store-find store 'project "1e+20"))))
  (test-assert
   'find-matches-canonical-character-spelling
   (eq? record (car (memory-store-find store 'project "#\\space"))))
  (test-assert
   'find-matches-canonical-bytevector-spelling
   (eq? record (car (memory-store-find store 'project "#u8(0 255)"))))
  (test-assert
   'select-matches-all-canonical-spellings
   (eq? record (car (memory-selection-records selection))))))

(testing-registry-case
 'text-query-fast-path-preserves-string-escaping
 '(portable agent memory boundary writer)
  (let* ((store (consent-make-memory-store))
         (record
          (memory-store-put!
           store
           'project
           'escaped-text
           (list
            (list
             'value
             (string-append "line" (string #\newline) "break"))))))
    (test-assert
     'plain-string-fragment-matches-directly
     (eq? record (car (memory-store-find store 'project "line"))))
    (test-assert
     'escaped-string-fragment-matches-canonical-text
     (eq? record (car (memory-store-find store 'project "\\n"))))
    (test-equal
     'raw-escaped-character-does-not-bypass-writer
     '()
     (memory-store-find store 'project (string #\newline)))))

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
  (test-error 'negative-selection-limit ((lambda ()
                 (memory-store-select
                  store
                  '(sensitive)
                  '(retrieval-policy (limit -1))
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

(testing-registry-case
 'lower-trust-redaction-graph-traversal '(portable agent)
(let* ((store (consent-make-memory-store))
       (sensitive-root
        (let* ((shared (cons 'ordinary '()))
               (graph
                (vector shared
                        shared
                        '(redaction (kind secret)))))
          (set-cdr! shared graph)
          graph))
       (clean-root
        (let* ((shared (cons 'ordinary '()))
               (graph (vector shared shared #f)))
          (set-cdr! shared graph)
          (vector-set! graph 2 graph)
          graph))
       (deep-root
        (let build ((remaining 8192) (result 'leaf))
          (if (= remaining 0)
              result
              (build (- remaining 1) (cons result '())))))
       (sensitive
        (memory-store-add!
         store
         'project
         'fact
         (list '(tags (graph-sensitive))
               (list 'value sensitive-root))))
       (clean
        (memory-store-add!
         store
         'project
         'fact
         (list '(tags (graph-clean)) (list 'value clean-root))))
       (deep
        (memory-store-add!
         store
         'project
         'fact
         (list '(tags (graph-deep)) (list 'value deep-root))))
       (selection
        (memory-store-select
         store
         '()
         '(retrieval-policy (cutoff 0))
         '(retrieval-context
           (scope project)
           (trust lower-trust)
           (allowed-scopes (project))
           (logical-clock 3))))
       (sensitive-candidate
        (candidate-for-id selection (memory-record-id sensitive)))
       (clean-candidate
        (candidate-for-id selection (memory-record-id clean)))
       (deep-candidate
        (candidate-for-id selection (memory-record-id deep))))
  (test-equal 'cyclic-shared-redaction-is-filtered
             'redaction-or-local-only
             (memory-record-field-value sensitive-candidate 'reason #f))
  (test-equal 'clean-pair-vector-cycle-terminates
             'selected
             (memory-record-field-value clean-candidate 'status #f))
  (test-equal 'deep-redaction-traversal-is-stack-safe
             'selected
             (memory-record-field-value deep-candidate 'status #f))
  (test-equal 'lower-trust-keeps-only-clean-graph-records
             2
             (length (memory-selection-records selection)))))

;;;; Exact arbitrary-key quotient ordering and persistent lifecycle

(testing-registry-case
 'arbitrary-key-quotient-order '(portable agent memory performance)
(let* ((pair-one (self-cdr-pair 'x))
       (pair-two (two-period-cdr-pair 'x))
       (vector-one (self-vector-cycle))
       (vector-two (two-period-vector-cycle))
       (shared-leaf (cons 'leaf 'tail))
       (shared-dag (vector shared-leaf shared-leaf))
       (duplicate-tree
        (vector (cons 'leaf 'tail) (cons 'leaf 'tail)))
       (late-left (late-leaf-key 1024 0))
       (late-right (late-leaf-key 1024 1))
       (pair-one-key (memory-prepare-index-key 'project pair-one))
       (pair-two-key (memory-prepare-index-key 'project pair-two))
       (vector-one-key (memory-prepare-index-key 'project vector-one))
       (vector-two-key (memory-prepare-index-key 'project vector-two))
       (dag-key (memory-prepare-index-key 'project shared-dag))
       (tree-key (memory-prepare-index-key 'project duplicate-tree))
       (late-left-key (memory-prepare-index-key 'project late-left))
       (late-right-key (memory-prepare-index-key 'project late-right)))
  (test-assert 'different-period-pair-cycles-are-equal
               (memory-index-key=? pair-one-key pair-two-key))
  (test-assert 'different-period-vector-cycles-are-equal
               (memory-index-key=? vector-one-key vector-two-key))
  (test-assert 'shared-dag-equals-duplicate-tree
               (memory-index-key=? dag-key tree-key))
  (test-assert 'unequal-late-leaf-stays-distinct
               (not (memory-index-key=? late-left-key late-right-key)))
  (let ((a0 (cons #f #f))
        (a1 (cons #f #f))
        (a2 (cons #f #f))
        (b0 (cons #f #f))
        (b2 (cons #f #f))
        (c0 (cons #f #f))
        (c1 (cons #f #f)))
    (set-car! a0 a0)
    (set-cdr! a0 a1)
    (set-car! a1 a1)
    (set-cdr! a1 a2)
    (set-car! a2 a1)
    (set-cdr! a2 1)
    (set-car! b0 b2)
    (set-cdr! b0 0)
    (set-car! b2 b0)
    (set-cdr! b2 b2)
    (set-car! c0 c1)
    (set-cdr! c0 c0)
    (set-car! c1 c1)
    (set-cdr! c1 1)
    (let* ((a (memory-prepare-index-key 'project a0))
           (b (memory-prepare-index-key 'project b0))
           (c (memory-prepare-index-key 'project c0))
           (keys (list a b c)))
      (test-assert
       'quotient-comparator-irreflexive
       (let loop ((rest keys))
         (or
          (null? rest)
          (and
           (not (memory-index-key<? (car rest) (car rest)))
           (loop (cdr rest))))))
      (test-assert
       'quotient-comparator-asymmetric
       (let outer ((left keys))
         (or
          (null? left)
          (and
           (let inner ((right keys))
             (or
              (null? right)
              (and
               (not
                (and
                 (memory-index-key<? (car left) (car right))
                 (memory-index-key<? (car right) (car left))))
               (inner (cdr right)))))
           (outer (cdr left))))))
      (test-assert
       'quotient-comparator-transitive-dfs-counterexample
       (let first ((xs keys))
         (or
          (null? xs)
          (and
           (let second ((ys keys))
             (or
              (null? ys)
              (and
               (let third ((zs keys))
                 (or
                  (null? zs)
                  (and
                   (or
                    (not
                     (and
                      (memory-index-key<? (car xs) (car ys))
                      (memory-index-key<? (car ys) (car zs))))
                    (memory-index-key<? (car xs) (car zs)))
                   (third (cdr zs)))))
               (second (cdr ys)))))
           (first (cdr xs))))))))))

(testing-registry-case
 'cyclic-key-store-query-lifecycle '(portable agent memory)
(let* ((store (consent-make-memory-store))
       (a (self-cdr-pair 1))
       (same-a (two-period-cdr-pair 1))
       (c0 (cons #f #f))
       (c1 (cons #f #f)))
  (set-car! c0 c1)
  (set-cdr! c0 0)
  (set-car! c1 c0)
  (set-cdr! c1 c1)
  (memory-store-put!
   store 'project c0 '((tags (separator)) (value "separator")))
  (let* ((first
          (memory-store-put!
           store
           'project
           a
           (list (list 'tags (list same-a))
                 '(value "cyclic first"))))
         (found (memory-store-ref store 'project same-a))
         (updated
          (memory-store-put!
           store
           'project
           same-a
           (list (list 'tags (list a))
                 '(value "cyclic updated"))))
         (tagged (memory-store-by-tag store 'project same-a))
         (whole (memory-store-find store 'project updated))
         (selection
          (memory-store-select
           store
           (list a 'datum)
           '(retrieval-policy
             (weights ((recency 0) (importance 0) (relevance 1)))
             (cutoff 0)
             (limit 1))
           '(retrieval-context
             (scope project)
             (trust local)
             (allowed-scopes (project))
             (logical-clock 3))))
         (candidate (candidate-for-value selection "cyclic updated"))
         (subscores
          (memory-record-field-value candidate 'subscores '())))
    (test-assert 'cyclic-clone-lookup-crosses-separator
                 (eq? first found))
    (test-assert 'cyclic-update-reuses-first-id
                 (eq? a (memory-record-id updated)))
    (test-equal 'cyclic-tag-projection
                (list updated)
                tagged)
    (test-equal 'nontext-whole-record-find
                (list updated)
                whole)
    (test-equal 'cyclic-key-and-kind-term-relevance
                2
                (memory-record-field-value subscores 'relevance #f))
    (memory-store-access! store same-a 'project 'cyclic-access)
    (test-assert 'cyclic-access-target-is-queryable
                 (pair? (memory-store-select
                         store
                         (list same-a)
                         '(retrieval-policy (cutoff 0) (limit 1))
                         '(retrieval-context
                           (scope project)
                           (trust local)
                           (allowed-scopes (project))
                           (logical-clock 4)))))
    (test-assert 'cyclic-delete-returns-current
                 (eq? updated
                      (memory-store-delete! store 'project same-a)))
    (test-equal 'cyclic-tombstone-removes-live-key
                #f
                (memory-store-ref store 'project a)))))

(testing-registry-case
 'bounded-general-key-equivalence-oracle '(portable agent memory)
(let* ((codes '(0 1 2 3 5 10 17 34 51 68 85 102 153 170 204 255))
       (graphs (map pair-graph-from-code codes))
       (keys
        (map
         (lambda (graph)
           (memory-prepare-index-key 'project graph))
         graphs)))
  (test-assert
   'bounded-general-key-equivalence-oracle
   (let outer ((left-graphs graphs) (left-keys keys))
     (or
      (null? left-graphs)
      (and
       (let inner ((right-graphs graphs) (right-keys keys))
         (or
          (null? right-graphs)
          (and
           (eqv?
            (reference-regular-tree-equal?
             (car left-graphs) (car right-graphs))
            (memory-index-key=? (car left-keys) (car right-keys)))
           (inner (cdr right-graphs) (cdr right-keys)))))
       (outer (cdr left-graphs) (cdr left-keys))))))))

(testing-registry-case
 'compound-key-alias-snapshots '(portable agent memory mutation)
(let ((exercise
       (lambda (name key old-clone mutate! new-clone)
         (let* ((store (consent-make-memory-store))
                (record
                 (memory-store-put!
                  store
                  'project
                  key
                  (list '(tags (alias)) (list 'value name)))))
           (mutate!)
           (let ((old-result
                  (memory-store-ref store 'project old-clone))
                 (new-result
                  (memory-store-ref store 'project new-clone)))
             (memory-store-replace-records!
              store (memory-store-records store))
             (list
              (eq? record old-result)
              new-result
              (memory-record-field-value
               (memory-store-ref store 'project new-clone)
               'value
               #f)))))))
  (let* ((pair-key (cons 'a 'b))
         (vector-key (vector 'a 'b))
         (string-key (string-copy "ab"))
         (bytevector-key (bytevector 1 2))
         (results
          (list
           (exercise
            'pair
            pair-key
            (cons 'a 'b)
            (lambda () (set-car! pair-key 'z))
            (cons 'z 'b))
           (exercise
            'vector
            vector-key
            (vector 'a 'b)
            (lambda () (vector-set! vector-key 0 'z))
            (vector 'z 'b))
           (exercise
            'string
            string-key
            (string-copy "ab")
            (lambda () (string-set! string-key 0 #\z))
            (string-copy "zb"))
           (exercise
            'bytevector
            bytevector-key
            (bytevector 1 2)
            (lambda () (bytevector-u8-set! bytevector-key 0 9))
            (bytevector 9 2)))))
    (test-equal
     'compound-alias-append-and-replace-semantics
     '((#t #f pair)
       (#t #f vector)
       (#t #f string)
       (#t #f bytevector))
     results))))

(testing-registry-case
 'shared-general-key-session-scale '(portable agent memory performance)
(let* ((size (if memory-scale-host-run? 256 1024))
       (shared (late-leaf-key size 7))
       (large-symbol
        (string->symbol (repeat-fragment "shared-symbol-" size)))
       (large-number (expt 2 (* 8 size)))
       (session-result
        (call-with-memory-index-key-session
         (lambda (prepare)
           (let* ((first (prepare 'project shared))
                  (other-scope (prepare 'session shared))
                  (symbol-key (prepare 'project large-symbol))
                  (number-key (prepare 'project large-number)))
             (let loop ((remaining size) (all-shared? #t))
               (if (= remaining 0)
                   (list
                    all-shared?
                    (eq? (vector-ref first 2)
                         (vector-ref other-scope 2))
                    (eq? symbol-key (prepare 'project large-symbol))
                    (eq? number-key (prepare 'project large-number)))
                   (loop
                    (- remaining 1)
                    (and all-shared?
                         (eq? first (prepare 'project shared)))))))))))
  (test-equal 'shared-root-session-interns-one-full-descriptor
              '(#t #t #t #t)
              session-result)
  (let ((sizes (if memory-scale-host-run?
                   '(16 64 256)
                   '(64 256 1024))))
    (test-assert
     'general-key-64-256-1024-scale
     (let loop ((rest sizes))
       (or
        (null? rest)
        (let* ((length (car rest))
               (left (late-leaf-key length 0))
               (right (late-leaf-key length 1))
               (left-key
                (memory-prepare-index-key 'project left))
               (right-key
                (memory-prepare-index-key 'project right)))
          (and
           (not (memory-index-key=? left-key right-key))
           (or (memory-index-key<? left-key right-key)
               (memory-index-key<? right-key left-key))
           (loop (cdr rest))))))))))

(testing-registry-case
 'memory-key-session-dynamic-extent '(portable agent memory safety)
(let ((escaped #f)
      (continuation #f)
      (exception-observed? #f)
      (first-continuation-return? #t)
      (reentry-result #f))
  (call-with-memory-index-key-session
   (lambda (prepare)
     (set! escaped prepare)
     (prepare 'project '(escaped preparer))))
  (test-error
   'memory-key-session-rejects-escaped-preparer
   ((lambda () (escaped 'project '(after exit)))))
  (guard
   (condition
    (else (set! exception-observed? #t)))
   (call-with-memory-index-key-session
    (lambda (prepare)
      (prepare 'project (late-leaf-key 32 1))
      (error "session release probe"))))
  (test-assert 'memory-key-session-releases-after-exception
               exception-observed?)
  (test-assert
   'memory-key-session-next-call-survives-exception
   (memory-index-key=?
    (memory-prepare-index-key 'project '(next session))
    (call-with-memory-index-key-session
     (lambda (prepare) (prepare 'project '(next session))))))
  ;; Invoking CONTINUATION resumes its complete captured continuation.  Escape
  ;; through FINISH after the guard observes the rejected dynamic-wind reentry
  ;; so the test does not replay the registry's own suite finalization.
  (let ((saved-runner (test-runner-current)))
    (set!
     reentry-result
     (call/cc
      (lambda (finish)
        (guard
         (condition (else (finish 'blocked)))
         (let ((value
                (call-with-memory-index-key-session
                 (lambda (prepare)
                   (call/cc
                    (lambda (return)
                      (set! continuation return)
                      (prepare 'project '(continuation session))))))))
           (if first-continuation-return?
               (begin
                 (set! first-continuation-return? #f)
                 (continuation 'reentered))
               (finish value)))))))
    ;; A rejected dynamic-wind before thunk may temporarily leave parameter
    ;; guards unwound; restore the registry runner before recording the result.
    (test-runner-current saved-runner))
  (test-equal
   'memory-key-session-rejects-continuation-reentry
   'blocked
   reentry-result)))

(testing-registry-case
 'shared-general-tag-append-session '(portable agent memory performance)
(let* ((size (if memory-scale-host-run? 64 256))
       (shared (late-leaf-key size 13))
       (tags
        (let loop ((remaining size) (result '()))
          (if (= remaining 0)
              result
              (loop (- remaining 1) (cons shared result)))))
       (store (consent-make-memory-store))
       (record
        (memory-store-put!
         store
         'project
         'shared-tag-record
         (list (list 'tags tags) '(value "shared tag payload")))))
  (test-assert 'shared-general-tag-append-preserves-record
               (eq? record
                    (car (memory-store-by-tag store 'project shared))))
  (test-equal 'shared-general-tag-append-preserves-occurrences
              size
              (length (memory-record-field-value record 'tags '())))))

(testing-registry-case
 'shared-general-query-term-scale '(portable agent memory performance)
(let* ((size (if memory-scale-host-run? 64 256))
       (term (late-leaf-key size 9))
       (terms
        (let loop ((remaining size) (result '()))
          (if (= remaining 0)
              result
              (loop (- remaining 1) (cons term result)))))
       (store (consent-make-memory-store))
       (record
        (memory-store-put!
         store 'project term '((value "shared query term"))))
       (selection
        (memory-store-select
         store
         terms
         (list
          'retrieval-policy
          '(weights ((recency 0) (importance 0) (relevance 1)))
          '(cutoff 0)
          '(limit 1))
         '(retrieval-context
           (scope project)
           (trust local)
           (allowed-scopes (project))
           (logical-clock 1))))
       (candidate (candidate-for-id selection (memory-record-id record)))
       (subscores
        (memory-record-field-value candidate 'subscores '())))
  (test-equal 'shared-general-query-term-validates-once-per-identity
              size
              (memory-record-field-value subscores 'relevance #f))))

(testing-registry-case
 'bounded-fast-list-and-total-key-validation '(portable agent memory)
(let* ((small
        (memory-prepare-index-key 'project '(agent helper 1)))
       (large-count-datum
        (let loop ((remaining 17) (result '()))
          (if (= remaining 0)
              result
              (loop (- remaining 1) (cons 'part result)))))
       (large-count
        (memory-prepare-index-key 'project large-count-datum))
       (large-token
        (memory-prepare-index-key
         'project
         (list
          (string->symbol (repeat-fragment "long-token" 20)))))
       (malformed
        (vector (vector-ref small 0)
                (vector-ref small 1)
                (vector "not-a-list-tag" "payload"))))
  (test-assert 'small-list-keeps-bounded-comparison-path
               (memory-index-key-bounded-comparison? small))
  (test-assert 'large-list-count-routes-to-general-normalizer
               (not (memory-index-key-bounded-comparison? large-count)))
  (test-assert 'large-list-token-routes-to-general-normalizer
               (not (memory-index-key-bounded-comparison? large-token)))
  (test-equal 'malformed-list-tag-predicate-is-total
              #f
              (memory-index-key? malformed))))

(testing-registry-case
 'cross-scope-record-flags-and-allowed-scope-validation
 '(portable agent memory)
(let* ((store (consent-make-memory-store))
       (session-record
        (memory-store-put!
         store 'session 'session-key '((value "session"))))
       (project-record
        (memory-store-put!
         store 'project 'project-key '((value "project"))))
       (cyclic-scopes (cons 'project '())))
  (set-cdr! cyclic-scopes cyclic-scopes)
  (test-equal 'nontext-record-find-keeps-global-scope-alignment
              (list project-record)
              (memory-store-find store 'project project-record))
  (test-equal 'nontext-record-find-aligns-second-scope
              (list session-record)
              (memory-store-find store 'session session-record))
  (test-error
   'selection-rejects-improper-allowed-scopes
   ((lambda ()
      (memory-store-select
       store
       'project-key
       '(retrieval-policy (cutoff 0))
       '(retrieval-context
         (scope project)
         (allowed-scopes (project . session)))))))
  (test-error
   'selection-rejects-cyclic-allowed-scopes
   ((lambda ()
      (memory-store-select
       store
       'project-key
       '(retrieval-policy (cutoff 0))
       (list 'retrieval-context
             '(scope project)
             (list 'allowed-scopes cyclic-scopes))))))
  (test-error
   'selection-rejects-unknown-allowed-scope
   ((lambda ()
      (memory-store-select
       store
       'project-key
       '(retrieval-policy (cutoff 0))
       '(retrieval-context
         (scope project)
         (allowed-scopes (project workspace)))))))))

(testing-runner-main "Consent Agent Memory portable tests" (command-line))
