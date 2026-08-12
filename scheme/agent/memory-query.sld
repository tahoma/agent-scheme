;;; Stateless native query kernel for portable Consent Scheme memory.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This internal library owns call-scoped memory retrieval algorithms.  The
;;; public (agent memory) facade owns every mutable store and passes only its
;;; current live records, detached identity sidecars, access maxima, and scalar
;;; next-id clock.  Textual queries render borrowed records read-only; equality
;;; never traverses identity-sensitive record fields.  No query value is
;;; retained, and returned record subobjects preserve their owned identity.

(define-library (agent memory-query)
  (export memory-query-find
          memory-query-by-tag
          memory-query-recent
          memory-query-select)
  (import (scheme base)
          (only (agent memory-key)
                memory-index-key?
                memory-index-key-sealed-wrapper?
                memory-index-key-bounded-comparison?
                memory-index-key<?
                memory-index-key=?
                memory-index-key-symbol-name)
          (only (consent identity-map)
                consent-identity-map-fast-backend?
                consent-make-identity-map
                consent-identity-map-ref
                consent-identity-map-set!)
          (only (consent reader) consent-datum->external)
          (only (data avl-tree)
                make-avl-tree
                avl-tree-ref
                avl-tree-set
                avl-tree-fold)
          (only (stdlib list) filter take))
  (begin
    ;; Query views are immutable and call-local.  Their records remain owned by
    ;; the source-backed public facade across the native borrowed-compound call.
    (define-record-type <memory-query-view>
      (make-memory-query-view-record
       records projections next-id key=? valid-key?)
      memory-query-view?
      (records store-records)
      (projections store-projections)
      (next-id store-next-id)
      (key=? store-key=?)
      (valid-key? store-valid-key?))

(define (memory-key-sidecar-live-key sidecar)
  "Return SIDECAR's detached live-key descriptor."
      (vector-ref sidecar 0))

(define (memory-key-sidecar-id-key sidecar)
  "Return SIDECAR's detached id descriptor."
      (vector-ref sidecar 1))

(define (memory-key-sidecar-access-target-key sidecar)
  "Return SIDECAR's detached access-target descriptor."
      (vector-ref sidecar 2))

(define (memory-key-sidecar-kind-key sidecar)
  "Return SIDECAR's detached kind descriptor."
      (vector-ref sidecar 3))

(define (memory-key-sidecar-tag-keys sidecar)
  "Return SIDECAR's detached tag descriptor vector."
      (vector-ref sidecar 4))

(define (memory-key-sidecar-flags sidecar)
  "Return SIDECAR's immutable classification flags."
      (vector-ref sidecar 5))

(define (memory-live-projection-sidecar projection)
  "Return live PROJECTION's append-time sidecar."
      (vector-ref projection 0))

(define (memory-live-projection-access-sequence projection)
  "Return live PROJECTION's latest access sequence."
      (vector-ref projection 1))

;; Bit marking source-classified restricted record content.
(define memory-sidecar-redaction-flag 4)

(define (memory-key-sidecar-flag? sidecar flag)
  "Return #t when SIDECAR contains FLAG."
      (not (= (modulo (quotient
                       (memory-key-sidecar-flags sidecar)
                       flag)
                      2)
              0)))

(define (memory-key-sidecar-redaction? sidecar)
  "Return #t when SIDECAR marks restricted content."
      (memory-key-sidecar-flag? sidecar memory-sidecar-redaction-flag))

(define (memory-key-vector? value scope valid-key?)
  "Return #t when VALUE is a valid descriptor vector for SCOPE."
      (and
       (vector? value)
       (let loop ((index 0))
         (or
          (= index (vector-length value))
          (let ((key (vector-ref value index)))
            (and
             (valid-key? key)
             (string=? scope (vector-ref key 0))
             (loop (+ index 1))))))))

(define (memory-key-sidecar? value valid-key?)
  "Return #t when VALUE is a valid detached query sidecar."
      (and
       (vector? value)
       (= (vector-length value) 6)
       (valid-key? (memory-key-sidecar-live-key value))
       (valid-key? (memory-key-sidecar-id-key value))
       (let* ((live-scope
               (vector-ref (memory-key-sidecar-live-key value) 0))
              (id-scope
               (vector-ref (memory-key-sidecar-id-key value) 0))
              (access-key
               (memory-key-sidecar-access-target-key value))
              (kind-key (memory-key-sidecar-kind-key value))
              (flags (memory-key-sidecar-flags value)))
         (and
          (string=? live-scope id-scope)
          (valid-key? kind-key)
          (string=? live-scope (vector-ref kind-key 0))
          (memory-key-vector?
           (memory-key-sidecar-tag-keys value)
           live-scope
           valid-key?)
          (integer? flags)
          (exact? flags)
          (or (= flags 0) (= flags memory-sidecar-redaction-flag))
          (eq? access-key #f)))))

    (define (memory-live-projection? value valid-key?)
      "Return #t for one sealed live sidecar and access-sequence pair."
      (and
       (vector? value)
       (= (vector-length value) 2)
       (memory-key-sidecar?
        (memory-live-projection-sidecar value) valid-key?)
       (let ((sequence
              (memory-live-projection-access-sequence value)))
         (and (integer? sequence) (exact? sequence) (>= sequence 0)))))

    (define (proper-acyclic-list? value)
      "Return #t when VALUE is a finite proper list."
      (let loop ((slow value) (fast value))
        (cond
         ((null? fast) #t)
         ((not (pair? fast)) #f)
         (else
          (let ((fast-one (cdr fast)))
            (cond
             ((null? fast-one) #t)
             ((not (pair? fast-one)) #f)
             (else
              (let ((slow-one (cdr slow))
                    (fast-two (cdr fast-one)))
                (and (not (eq? slow-one fast-two))
                     (loop slow-one fast-two))))))))))

    (define (make-memory-query-view records projections next-id)
      "Validate aligned detached live projections and return a query view."
      (if (not (and (integer? next-id) (exact? next-id) (>= next-id 0)))
          (error "memory query next id must be a nonnegative exact integer"
                 next-id))
      (let ((fast? (consent-identity-map-fast-backend?))
            (validated
             (and (consent-identity-map-fast-backend?)
                  (consent-make-identity-map)))
            (absent (vector 'absent)))
        (define (valid-key-once? key)
          (if (not fast?)
              ;; This sealed ABI is created only by the source facade.  A
              ;; constant-time envelope check keeps no-hash compatibility from
              ;; rescanning one shared K-token descriptor N times. Configured
              ;; product routes below fully validate each identity once.
              (memory-index-key-sealed-wrapper? key)
              (let ((known
                     (consent-identity-map-ref validated key absent)))
                (if (eq? known absent)
                    (let ((valid? (memory-index-key? key)))
                      (consent-identity-map-set! validated key valid?)
                      valid?)
                    known))))
        (define (safe-key=? left right)
          (cond
           ((eq? left right) #t)
           (fast? (memory-index-key=? left right))
           ((and (memory-index-key-bounded-comparison? left)
                 (memory-index-key-bounded-comparison? right))
            (memory-index-key=? left right))
           (else
            (error
             "unbounded memory key comparison requires fast identity map"
             left
             right))))
        (if (not (and (proper-acyclic-list? records)
                      (proper-acyclic-list? projections)))
            (error "memory query records/projections must be finite lists"))
        (let loop ((record-rest records) (projection-rest projections))
          (cond
           ((and (null? record-rest) (null? projection-rest)) #t)
           ((or (null? record-rest) (null? projection-rest))
            (error "memory query records/projections are not aligned"))
           ((not (memory-live-projection?
                  (car projection-rest)
                  valid-key-once?))
            (error "memory query received invalid live projection"
                   (car projection-rest)))
           (else
            (loop (cdr record-rest) (cdr projection-rest)))))
      (make-memory-query-view-record
       records projections next-id safe-key=? valid-key-once?)))

    (define (integer-value value)
      "Validate and return VALUE for memory count arguments."
      (if (and (integer? value) (exact? value))
          value
          (error "memory count must be an exact integer" value)))

    (define (numeric-value value)
      "Validate and return VALUE for memory scoring."
      (if (number? value)
          value
          (error "memory score must be numeric" value)))

    (define (memory-number? value)
      "Return #t when VALUE is a number."
      (number? value))
    ;; Public memory scopes mirror the Consent Scheme architecture document.
    (define consent-memory-scopes
      '(instance session project))
    ;; Ranking entries cache every comparison key and use the candidate's
    ;; projection ordinal as its identity.  No mutation is needed while
    ;; sorting or matching selected candidates back into receipt order.
    (define-record-type <ranked-candidate-entry>
      (make-ranked-candidate-entry ordinal candidate score tie-key)
      ranked-candidate-entry?
      (ordinal ranked-candidate-entry-ordinal)
      (candidate ranked-candidate-entry-candidate)
      (score ranked-candidate-entry-score)
      (tie-key ranked-candidate-entry-tie-key))
    (define (member-equal? value list)
      "Report whether VALUE appears in LIST using equal?."
      (cond
       ((null? list) #f)
       ((equal? value (car list)) #t)
       (else (member-equal? value (cdr list)))))

    (define (normalize-scope scope)
      "Validate and return SCOPE."
      (if (member-equal? scope consent-memory-scopes)
          scope
          (error "unknown memory scope" scope)))

    (define (finite-proper-list? value)
      "Return #t when VALUE is a finite proper list."
      (let loop ((slow value) (fast value))
        (cond
         ((null? fast) #t)
         ((not (pair? fast)) #f)
         (else
          (let ((fast-one (cdr fast)))
            (cond
             ((null? fast-one) #t)
             ((not (pair? fast-one)) #f)
             (else
              (let ((slow-one (cdr slow))
                    (fast-two (cdr fast-one)))
                (and (not (eq? slow-one fast-two))
                     (loop slow-one fast-two))))))))))

    (define (field-value datum name)
      "Return field NAME from RECORD or payload DATUM, or #f."
      (let ((fields (if (and (pair? datum) (eq? (car datum) 'memory))
                        (cdr datum)
                        datum)))
        (if (not (finite-proper-list? fields))
            (error "memory fields must be a finite proper list" datum))
        (let loop ((rest fields))
          (cond
           ((null? rest) #f)
           ((and (pair? (car rest))
                 (eq? (caar rest) name))
            (cadr (car rest)))
           (else (loop (cdr rest)))))))

    (define (field-value/default datum name default)
      "Return field NAME from DATUM, or DEFAULT when NAME is absent."
      (let ((fields (if (and (pair? datum)
                             (symbol? (car datum))
                             (not (and (pair? (car datum))
                                       (symbol? (caar datum)))))
                        (cdr datum)
                        datum)))
        (if (not (finite-proper-list? fields))
            (error "memory fields must be a finite proper list" datum))
        (let loop ((rest fields))
          (cond
           ((null? rest) default)
           ((and (pair? (car rest))
                 (eq? (caar rest) name))
            (cadr (car rest)))
           (else (loop (cdr rest)))))))

    (define (memory-record-id record)
      "Return canonical id field from a memory RECORD."
      #((parameters
         (record (type list)
          (description "Memory record datum.")))
        (returns (type symbol)
         (description "The record id field."))
        (effects pure))
      (field-value record 'id))
    (define (memory-record-sequence record)
      "Return RECORD's highest timestamp sequence, or zero when absent."
      (max
       (let ((created-at (field-value record 'created-at)))
         (if created-at (integer-value created-at) 0))
       (let ((updated-at (field-value record 'updated-at)))
         (if updated-at (integer-value updated-at) 0))))

    (define (memory-string->character-vector text)
      "Copy TEXT to a vector through one sequential host traversal."
      ;; R7RS permits variable-width strings whose indexed access is not O(1).
      ;; Pattern preprocessing needs random access, so pay for exactly one
      ;; sequential copy and index only the resulting vector.
      (let ((characters (make-vector (string-length text) #f))
            (index 0))
        (string-for-each
         (lambda (character)
           (vector-set! characters index character)
           (set! index (+ index 1)))
         text)
        characters))

    ;; Private prepared patterns have no mutable fields and never enter the
    ;; public memory datum surface.  The prefix table is the Knuth-Morris-Pratt
    ;; failure function, independently derived from
    ;; https://doi.org/10.1137/0206024.
    (define-record-type <memory-substring-pattern>
      (make-memory-substring-pattern needle length fallback)
      memory-substring-pattern?
      (needle memory-substring-pattern-needle)
      (length memory-substring-pattern-length)
      (fallback memory-substring-pattern-fallback))

    (define (memory-substring-fallback-table needle length)
      "Return the linear-time prefix fallback table for NEEDLE."
      (let ((fallback (make-vector length 0)))
        (let loop ((index 1) (matched 0))
          (cond
           ((>= index length) fallback)
           ((char=? (vector-ref needle index)
                    (vector-ref needle matched))
            (let ((next (+ matched 1)))
              (vector-set! fallback index next)
              (loop (+ index 1) next)))
           ((> matched 0)
            (loop index (vector-ref fallback (- matched 1))))
           (else
            (loop (+ index 1) 0))))))

    (define (prepare-memory-substring-pattern needle-text)
      "Build a linear-time reusable search pattern for NEEDLE-TEXT."
      (let* ((needle (memory-string->character-vector needle-text))
             (length (vector-length needle)))
        (make-memory-substring-pattern
         needle
         length
         (memory-substring-fallback-table needle length))))

    (define (prepared-memory-substring-occurs? pattern haystack)
      "Return #t when prepared PATTERN occurs in string HAYSTACK."
      (let ((needle (memory-substring-pattern-needle pattern))
            (length (memory-substring-pattern-length pattern))
            (fallback (memory-substring-pattern-fallback pattern)))
        (if (= length 0)
            #t
            (call-with-current-continuation
             (lambda (return)
               (let ((matched 0))
                 (string-for-each
                  (lambda (character)
                    (let retreat ((candidate matched))
                      (cond
                       ((char=? character
                                (vector-ref needle candidate))
                        (let ((next (+ candidate 1)))
                          (if (= next length)
                              (return #t)
                              (set! matched next))))
                       ((> candidate 0)
                        (retreat
                         (vector-ref fallback (- candidate 1))))
                       (else
                        (set! matched 0)))))
                 haystack)
                 #f))))))

    ;; Select relevance uses one Aho-Corasick-style automaton for every
    ;; distinct textual term.  Direct transitions and completed fallback
    ;; transitions are persistent character AVL trees, so a failure map is
    ;; shared rather than copied into every state.  Terminal outputs remain
    ;; direct-only; output links and generation stamps prevent inherited
    ;; matches from producing quadratic storage or repeated reporting.
(define (make-memory-relevance-text-node)
  "Return one empty private multi-pattern automaton node."
      (vector (make-avl-tree char<?) #f #f '() #f 0))

(define (relevance-text-node-direct node)
  "Return NODE's direct character transitions."
      (vector-ref node 0))

(define (set-relevance-text-node-direct! node transitions)
  "Set NODE's direct character TRANSITIONS."
      (vector-set! node 0 transitions))

(define (relevance-text-node-goto node)
  "Return NODE's completed character transitions."
      (vector-ref node 1))

(define (set-relevance-text-node-goto! node transitions)
  "Set NODE's completed character TRANSITIONS."
      (vector-set! node 1 transitions))

(define (relevance-text-node-failure node)
  "Return NODE's failure transition."
      (vector-ref node 2))

(define (set-relevance-text-node-failure! node failure)
  "Set NODE's FAILURE transition."
      (vector-set! node 2 failure))

(define (relevance-text-node-outputs node)
  "Return NODE's direct terminal group identifiers."
      (vector-ref node 3))

(define (set-relevance-text-node-outputs! node outputs)
  "Set NODE's direct terminal group OUTPUTS."
      (vector-set! node 3 outputs))

(define (relevance-text-node-output-link node)
  "Return NODE's nearest terminal failure ancestor."
      (vector-ref node 4))

(define (set-relevance-text-node-output-link! node output-link)
  "Set NODE's terminal failure OUTPUT-LINK."
      (vector-set! node 4 output-link))

(define (relevance-text-node-generation node)
  "Return NODE's most recent record-scan generation."
      (vector-ref node 5))

(define (set-relevance-text-node-generation! node generation)
  "Set NODE's record-scan GENERATION."
      (vector-set! node 5 generation))

    (define (relevance-text-add-pattern! root text group)
      "Add TEXT's direct terminal GROUP to trie ROOT."
      (let ((state root))
        (string-for-each
         (lambda (character)
           (let* ((direct (relevance-text-node-direct state))
                  (next
                   (avl-tree-ref direct character (lambda () #f))))
             (if next
                 (set! state next)
                 (let ((created (make-memory-relevance-text-node)))
                   (set-relevance-text-node-direct!
                    state
                    (avl-tree-set direct character created))
                   (set! state created)))))
         text)
        (set-relevance-text-node-outputs!
         state
         (cons group (relevance-text-node-outputs state)))))

    (define (relevance-text-completed-goto direct inherited)
      "Overlay DIRECT transitions on INHERITED persistent transitions."
      (avl-tree-fold
       (lambda (character next result)
         (avl-tree-set result character next))
       inherited
       direct))

    (define (complete-memory-relevance-text-automaton! root)
      "Install failure, output, and completed-goto links below ROOT."
      (let ((front '()) (back '()))
        (define (enqueue! node)
          (set! back (cons node back)))
        (define (dequeue!)
          (if (null? front)
              (begin
                (set! front (reverse back))
                (set! back '())))
          (if (null? front)
              #f
              (let ((node (car front)))
                (set! front (cdr front))
                node)))
        (set-relevance-text-node-failure! root root)
        (set-relevance-text-node-goto!
         root
         (relevance-text-node-direct root))
        (avl-tree-fold
         (lambda (character child ignored)
           (set-relevance-text-node-failure! child root)
           (set-relevance-text-node-output-link!
            child
            (and
             (not (null? (relevance-text-node-outputs root)))
             root))
           (enqueue! child)
           ignored)
         #f
         (relevance-text-node-direct root))
        (let loop ((state (dequeue!)))
          (if state
              (let* ((failure (relevance-text-node-failure state))
                     (inherited
                      (relevance-text-node-goto failure)))
                (set-relevance-text-node-goto!
                 state
                 (relevance-text-completed-goto
                  (relevance-text-node-direct state)
                  inherited))
                (avl-tree-fold
                 (lambda (character child ignored)
                   (let ((child-failure
                          (avl-tree-ref
                           inherited character (lambda () root))))
                     (set-relevance-text-node-failure!
                      child child-failure)
                     (set-relevance-text-node-output-link!
                      child
                      (if (null?
                           (relevance-text-node-outputs child-failure))
                          (relevance-text-node-output-link child-failure)
                          child-failure))
                     (enqueue! child)
                     ignored))
                 #f
                 (relevance-text-node-direct state))
                (loop (dequeue!)))))
        root))

    (define (relevance-text-next root state character)
      "Return STATE's completed transition for CHARACTER."
      (avl-tree-ref
       (relevance-text-node-goto state)
       character
       (lambda () root)))

    (define (memory-query-entries store)
      "Return validated current-live entries in source ordinal order."
      (let loop ((records (store-records store))
                 (projections (store-projections store))
                 (ordinal 0)
                 (reversed '()))
        (if (null? records)
            (reverse reversed)
            (let ((projection (car projections)))
              (loop
               (cdr records)
               (cdr projections)
               (+ ordinal 1)
               (cons
                (vector
                 ordinal
                 (car records)
                 (memory-live-projection-sidecar projection)
                 (memory-live-projection-access-sequence projection))
                reversed))))))

    (define (scope-entries store scope)
      "Return aligned entries in SCOPE, newest first."
      (let ((normalized-scope
             (symbol->string (normalize-scope scope))))
        (let loop ((rest (memory-query-entries store))
                   (ordinal 0)
                   (scoped '()))
          (cond
           ((null? rest) (reverse scoped))
           ((string=?
             (vector-ref
              (memory-key-sidecar-live-key (vector-ref (car rest) 2)) 0)
             normalized-scope)
            (let ((entry (car rest)))
              (loop
               (cdr rest)
               (+ ordinal 1)
               (cons
                (vector
                 ordinal
                 (vector-ref entry 1)
                 (vector-ref entry 2)
                 (vector-ref entry 3))
                scoped))))
           (else (loop (cdr rest) ordinal scoped))))))

    (define (scope-live-entries store scope)
      "Return already-live entries in SCOPE, newest first."
      (scope-entries store scope))

    (define (all-live-entries store)
      "Return all already-live entries, newest first."
      (memory-query-entries store))

    (define (scope-live-records store scope)
      "Return live records from STORE belonging to SCOPE, newest first."
      (map (lambda (entry) (vector-ref entry 1))
           (scope-live-entries store scope)))

    (define (memory-key-vector-member? store key keys)
      "Return #t when detached KEY equals one descriptor in KEYS."
      (let loop ((index 0))
        (and
         (< index (vector-length keys))
         (or
          ((store-key=? store) key (vector-ref keys index))
          (loop (+ index 1))))))

    (define (memory-find-projection-parts
             store projection scope record-count)
      "Validate a detached find PROJECTION and return its prepared parts."
      (if (not (and (vector? projection)
                    (= (vector-length projection) 3)))
          (error "memory query received invalid find projection" projection))
      (let ((text (vector-ref projection 0))
            (key (vector-ref projection 1))
            (matches (vector-ref projection 2)))
        (cond
         ((and (string? text) (eq? key #f) (eq? matches #f))
          (vector text #f #f))
         ((and (string? text)
               ((store-valid-key? store) key)
               (string=? scope (vector-ref key 0))
               (eq? matches #f))
          (vector text key #f))
         ((and (eq? text #f)
               (eq? key #f)
               (proper-acyclic-list? matches)
               (= (length matches) record-count)
               (let loop ((rest matches))
                 (or
                  (null? rest)
                  (and
                   (boolean? (car rest))
                   (loop (cdr rest))))))
          (vector #f #f (list->vector matches)))
         (else
          (error "memory query received invalid find projection"
                 projection)))))

    (define (record-matches?
             store
             record
             sidecar
             ordinal
             text
             query-key
             match-vector
             pattern)
      "Report whether RECORD and SIDECAR match a source projection."
      (cond
       (match-vector (vector-ref match-vector ordinal))
       (query-key
        (or
         ((store-key=? store)
          query-key (memory-key-sidecar-kind-key sidecar))
         ((store-key=? store)
          query-key (memory-key-sidecar-live-key sidecar))
         (memory-key-vector-member?
          store query-key (memory-key-sidecar-tag-keys sidecar))
         (prepared-memory-substring-occurs?
          pattern (record-search-text record))))
       (else
        (prepared-memory-substring-occurs?
         pattern (record-search-text record)))))

    (define (memory-store-find store scope projection)
      "Return SCOPE records matching detached PROJECTION."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (projection (type vector)
          (description "Source-prepared find projection.")))
        (returns (type (list-of list))
         (description "List of matching memory record datums in SCOPE."))
        (effects state-read error))
      (let* ((scope-name (symbol->string (normalize-scope scope)))
             (entries (scope-entries store scope))
             (parts
              (memory-find-projection-parts
               store projection scope-name (length entries)))
             (text (vector-ref parts 0))
             (query-key (vector-ref parts 1))
             (match-vector (vector-ref parts 2))
             (pattern
              (and text (prepare-memory-substring-pattern text))))
        (map
         (lambda (entry) (vector-ref entry 1))
         (filter
          (lambda (entry)
            (record-matches?
             store
             (vector-ref entry 1)
             (vector-ref entry 2)
             (vector-ref entry 0)
             text
             query-key
             match-vector
             pattern))
          entries))))

    (define (memory-store-by-tag store scope tag-key)
      "Return SCOPE records carrying detached TAG-KEY."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (tag-key (type vector)
          (description "Detached scope-qualified tag descriptor.")))
        (returns (type (list-of list))
         (description "List of memory record datums whose tags include TAG."))
        (effects state-read error))
      (let ((scope-name (symbol->string (normalize-scope scope))))
        (if (not (and ((store-valid-key? store) tag-key)
                      (string=? scope-name (vector-ref tag-key 0))))
            (error "memory query received invalid tag projection" tag-key))
        (map
         (lambda (entry) (vector-ref entry 1))
         (filter
          (lambda (entry)
            (memory-key-vector-member?
             store
             tag-key
             (memory-key-sidecar-tag-keys (vector-ref entry 2))))
          (scope-live-entries store scope)))))

    (define (memory-store-recent store scope count)
      "Return COUNT newest memory records in SCOPE."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (count (type exact-integer)
          (description
           ("Exact nonnegative integer or Consent Scheme integer datum"
             "limiting result size."))))
        (returns (type (list-of list))
         (description "At most COUNT newest memory record datums in SCOPE."))
        (effects state-read error))
      (let* ((records (scope-live-records store scope))
             (limit (integer-value count)))
        (if (<= limit 0)
            '()
            (take records (min limit (length records))))))

    (define (ensure-bounded-text-record record)
      "Reject an unbounded no-hash graph before canonical serialization."
      (if (not (consent-identity-map-fast-backend?))
          (let ((seen (consent-make-identity-map))
                (absent (vector 'absent)))
            (let walk ((pending (list record)) (count 0))
              (if (null? pending)
                  #t
                  (let* ((value (car pending))
                         (rest (cdr pending))
                         (compound? (or (pair? value) (vector? value))))
                    (if (not compound?)
                        (walk rest count)
                        (let ((known
                               (consent-identity-map-ref
                                seen value absent)))
                          (if (not (eq? known absent))
                              (walk rest count)
                              (let ((next-count (+ count 1)))
                                (if (> next-count 64)
                                    (error
                                     (string-append
                                      "large text query requires fast "
                                      "identity map")
                                     record))
                                (consent-identity-map-set! seen value #t)
                                (if (pair? value)
                                    (walk
                                     (cons
                                      (car value)
                                      (cons (cdr value) rest))
                                     next-count)
                                    (let push
                                        ((index (- (vector-length value) 1))
                                         (next rest))
                                      (if (< index 0)
                                          (walk next next-count)
                                          (push
                                           (- index 1)
                                           (cons
                                            (vector-ref value index)
                                            next)))))))))))))))

    (define (record-search-text record)
      "Return RECORD's canonical external text for substring search."
      (ensure-bounded-text-record record)
      (consent-datum->external record))

    (define (redaction-sensitive? sidecar)
      "Return SIDECAR's source-owned restricted-content classification."
      (memory-key-sidecar-redaction? sidecar))

    (define (lower-trust? trust)
      "Return #t when TRUST names a lower-trust prompt boundary."
      (or (eq? trust 'remote)
          (eq? trust 'public)
          (eq? trust 'lower-trust)))

    (define (weight-ref weights name default)
      "Return NAME's weight from WEIGHTS, or DEFAULT."
      (let ((entry (assq name weights)))
        (if (and entry (pair? (cdr entry)))
            (numeric-value (cadr entry))
            default)))

    (define (policy-field policy name default)
      "Return POLICY field NAME, or DEFAULT."
      (field-value/default policy name default))

    (define (context-field context name default)
      "Return CONTEXT field NAME, or DEFAULT."
      (field-value/default context name default))

    (define (scope-position scope)
      "Return SCOPE's fixed public-scope position, or fail closed."
      (cond
       ((eq? scope 'instance) 0)
       ((eq? scope 'session) 1)
       ((eq? scope 'project) 2)
       (else (error "unknown memory scope" scope))))

    (define (normalize-allowed-scopes allowed-scopes)
      "Return a constant-size membership vector for ALLOWED-SCOPES."
      (if (not (proper-acyclic-list? allowed-scopes))
          (error "memory allowed-scopes must be a finite proper list"
                 allowed-scopes))
      (let ((membership (vector #f #f #f)))
        (let loop ((rest allowed-scopes))
          (if (null? rest)
              membership
              (let ((scope (car rest)))
                (if (not (symbol? scope))
                    (error "memory allowed scope must be a symbol" scope))
                (vector-set! membership (scope-position scope) #t)
                (loop (cdr rest)))))))

    (define (sidecar-scope-allowed? sidecar allowed-membership)
      "Return #t when SIDECAR's scope appears in ALLOWED-MEMBERSHIP."
      (let ((scope-name
             (vector-ref (memory-key-sidecar-live-key sidecar) 0)))
        (cond
         ((string=? scope-name "instance")
          (vector-ref allowed-membership 0))
         ((string=? scope-name "session")
          (vector-ref allowed-membership 1))
         ((string=? scope-name "project")
          (vector-ref allowed-membership 2))
         (else #f))))

    (define (pow2 exponent)
      "Return 2 raised to nonnegative integer EXPONENT."
      (expt 2 exponent))

    (define (recency-score logical-clock record access-sequence)
      "Return exact recency score for RECORD at LOGICAL-CLOCK."
      (let* ((record-sequence (memory-record-sequence record))
             (latest (max record-sequence access-sequence))
             (age (max 0 (- logical-clock latest))))
        (/ 1 (pow2 age))))

    (define (importance-score record)
      "Return RECORD's effective importance score."
      (let ((importance (field-value/default record 'importance 1)))
        (cond
         ((memory-number? importance)
          (numeric-value importance))
         ((pair? importance)
          (numeric-value
           (field-value/default importance
                                'effective
                                (field-value/default importance 'proposed 1))))
         (else 1))))

    (define (valid-query-term-key-vector? store keys)
      "Return #t for a three-scope vector of detached keys or #f slots."
      (and
       (vector? keys)
       (= (vector-length keys) (length consent-memory-scopes))
       (let loop ((index 0) (scopes consent-memory-scopes))
         (or
          (null? scopes)
          (let ((key (vector-ref keys index)))
            (and
             (or
              (eq? key #f)
              (and
               ((store-valid-key? store) key)
               (string=?
                (vector-ref key 0)
                (symbol->string (car scopes)))))
             (loop (+ index 1) (cdr scopes))))))))

;; Private grouped key and text indexes used by one select query.
(define-record-type <memory-relevance-index>
      (make-memory-relevance-index
       indexes text-root multiplicities marks count generation)
      memory-relevance-index?
      (indexes relevance-indexes)
      (text-root relevance-text-root)
      (multiplicities relevance-multiplicities)
      (marks relevance-marks)
      (count relevance-count)
      (generation relevance-generation set-relevance-generation!))

    (define (make-relevance-key-order fast?)
      "Return the exact descriptor order allowed by the active backend."
      (lambda (left right)
        (cond
         ((eq? left right) #f)
         ((or fast?
              (and
               (memory-index-key-bounded-comparison? left)
               (memory-index-key-bounded-comparison? right)))
          (memory-index-key<? left right))
         (else
          (error
           "unbounded memory key comparison requires fast identity map"
           left
           right)))))

    (define (make-relevance-key-indexes fast? key<?)
      "Return one structural/identity index per public memory scope."
      (list->vector
       (map
        (lambda (scope)
          (vector
           (make-avl-tree key<?)
           (and fast? (consent-make-identity-map))
           (vector 'absent)))
        consent-memory-scopes)))

    (define (relevance-key-index-add! indexes scope-index key term-index)
      "Associate TERM-INDEX with KEY in one scope index."
      (let* ((index (vector-ref indexes scope-index))
             (tree (vector-ref index 0))
             (identities (vector-ref index 1))
             (absent (vector-ref index 2))
             (cached
              (and identities
                   (consent-identity-map-ref identities key absent)))
             (bucket
              (if (and identities (not (eq? cached absent)))
                  cached
                  (or
                   (avl-tree-ref tree key (lambda () #f))
                   (let ((created (vector '())))
                     (vector-set! index 0 (avl-tree-set tree key created))
                     created)))))
        ;; Buckets are shared by every identity whose descriptor compares
        ;; equal. Mutating only the private term-index list keeps both the AVL
        ;; and identity shortcuts coherent without retaining pair matrices.
        (vector-set! bucket 0 (cons term-index (vector-ref bucket 0)))
        (if (and identities (eq? cached absent))
            (consent-identity-map-set! identities key bucket))))

    (define (normalize-query-term store projection)
      "Validate and prepare one detached relevance-term PROJECTION."
      (if (not (and (vector? projection)
                    (= (vector-length projection) 2)))
          (error "memory query received invalid term projection" projection))
      (let ((text (vector-ref projection 0))
            (keys (vector-ref projection 1)))
        (if (not (and (or (eq? text #f) (string? text))
                      (valid-query-term-key-vector? store keys)))
            (error "memory query received invalid term projection"
                   projection))
        (vector text keys)))

    (define (make-relevance-term-order key<?)
      "Return a total order for validated text/key term projections."
      (lambda (left right)
        (let ((left-text (vector-ref left 0))
              (right-text (vector-ref right 0)))
          (cond
           ((and (eq? left-text #f) right-text) #t)
           ((and left-text (eq? right-text #f)) #f)
           ((and left-text right-text (string<? left-text right-text)) #t)
           ((and left-text right-text (string<? right-text left-text)) #f)
           (else
            (let ((left-keys (vector-ref left 1))
                  (right-keys (vector-ref right 1)))
              (let loop ((index 0))
                (if (= index (vector-length left-keys))
                    #f
                    (let ((left-key (vector-ref left-keys index))
                          (right-key (vector-ref right-keys index)))
                      (cond
                       ((eq? left-key right-key) (loop (+ index 1)))
                       ((eq? left-key #f) #t)
                       ((eq? right-key #f) #f)
                       ((key<? left-key right-key) #t)
                       ((key<? right-key left-key) #f)
                       (else (loop (+ index 1)))))))))))))

    (define (normalize-query-terms store projections)
      "Normalize PROJECTIONS into linear-size relevance indexes."
      (if (not (vector? projections))
          (error "memory query term projections must be a vector"
                 projections))
      (let* ((count (vector-length projections))
             (fast? (consent-identity-map-fast-backend?))
             (key<? (make-relevance-key-order fast?))
             (known (and fast? (consent-make-identity-map)))
             (absent (vector 'absent))
             (term-groups
              (make-avl-tree (make-relevance-term-order key<?)))
             (indexes (make-relevance-key-indexes fast? key<?))
             (text-root (make-memory-relevance-text-node))
             (multiplicities (make-vector count 0))
             (marks (make-vector count 0))
             (group-count 0)
             (has-text? #f))
        (let term-loop ((occurrence-index 0))
          (if (= occurrence-index count)
              (make-memory-relevance-index
               indexes
               (and
                has-text?
                (complete-memory-relevance-text-automaton! text-root))
               multiplicities
               marks
               group-count
               0)
              (let* ((projection
                      (vector-ref projections occurrence-index))
                     (cached
                      (and known
                           (consent-identity-map-ref
                            known projection absent)))
                     (bucket
                      (if (and known (not (eq? cached absent)))
                          cached
                          (let* ((normalized
                                  (normalize-query-term store projection))
                                 (existing
                                  (avl-tree-ref
                                   term-groups
                                   normalized
                                   (lambda () #f)))
                                 (created
                                  (or
                                   existing
                                   (let* ((identifier group-count)
                                          (text
                                           (vector-ref normalized 0))
                                          (keys
                                           (vector-ref normalized 1))
                                          (new (vector identifier)))
                                     (set! term-groups
                                           (avl-tree-set
                                            term-groups normalized new))
                                     (vector-set!
                                      marks identifier 0)
                                     (if text
                                         (begin
                                           (set! has-text? #t)
                                           (relevance-text-add-pattern!
                                            text-root text identifier)))
                                     (let key-loop ((scope-index 0))
                                       (if (< scope-index
                                              (vector-length keys))
                                           (let ((key
                                                  (vector-ref
                                                   keys scope-index)))
                                             (if key
                                                 (relevance-key-index-add!
                                                  indexes
                                                  scope-index
                                                  key
                                                  identifier))
                                             (key-loop (+ scope-index 1)))))
                                     (set! group-count (+ group-count 1))
                                     new))))
                            (if known
                                (consent-identity-map-set!
                                 known projection created))
                            created))))
                (vector-set!
                 multiplicities
                 (vector-ref bucket 0)
                 (+ 1
                    (vector-ref multiplicities (vector-ref bucket 0))))
                (term-loop (+ occurrence-index 1)))))))

    (define (memory-scope-name-index name)
      "Return canonical scope NAME's relevance-index position, or #f."
      (cond
       ((string=? name "instance") 0)
       ((string=? name "session") 1)
       ((string=? name "project") 2)
       (else #f)))

    (define (mark-relevance-key! terms scope-index key generation)
      "Mark and count query terms associated with candidate KEY."
      (let* ((index
              (vector-ref (relevance-indexes terms) scope-index))
             (identities (vector-ref index 1))
             (absent (vector-ref index 2))
             (cached
              (and identities
                   (consent-identity-map-ref identities key absent)))
             (bucket
              (if (and identities (not (eq? cached absent)))
                  cached
                  (let ((found
                         (avl-tree-ref
                          (vector-ref index 0)
                          key
                          (lambda () #f))))
                    ;; Cache both structural aliases and definite misses so a
                    ;; shared candidate descriptor pays at most one AVL probe.
                    (if identities
                        (consent-identity-map-set!
                         identities key found))
                    found)))
             (indices (if bucket (vector-ref bucket 0) '()))
             (marks (relevance-marks terms))
             (multiplicities (relevance-multiplicities terms)))
        (let loop ((rest indices) (count 0))
          (cond
           ((null? rest) count)
           ((= (vector-ref marks (car rest)) generation)
            (loop (cdr rest) count))
           (else
            (vector-set! marks (car rest) generation)
            (loop
             (cdr rest)
             (+ count (vector-ref multiplicities (car rest)))))))))

    (define (mark-sidecar-relevance! terms sidecar generation)
      "Mark candidate SIDECAR's distinct key-relevant query terms."
      (let* ((live-key (memory-key-sidecar-live-key sidecar))
             (scope-index
              (memory-scope-name-index (vector-ref live-key 0))))
        (if (not scope-index)
            0
            (let ((kind-key (memory-key-sidecar-kind-key sidecar))
                  (tag-keys (memory-key-sidecar-tag-keys sidecar)))
              (let tag-loop
                  ((index 0)
                   (score
                    (+
                     (mark-relevance-key!
                      terms scope-index live-key generation)
                     (mark-relevance-key!
                      terms scope-index kind-key generation))))
                (if (= index (vector-length tag-keys))
                    score
                    (tag-loop
                     (+ index 1)
                     (+ score
                        (mark-relevance-key!
                         terms
                         scope-index
                         (vector-ref tag-keys index)
                         generation)))))))))

    (define (relevance-score terms record sidecar)
      "Return exact key/text relevance using linear-size scratch indexes."
      (let ((generation (+ (relevance-generation terms) 1)))
        (set-relevance-generation! terms generation)
        (let ((key-score
               (mark-sidecar-relevance! terms sidecar generation))
              (marks (relevance-marks terms))
              (text-root (relevance-text-root terms))
              (multiplicities (relevance-multiplicities terms))
              (count (relevance-count terms)))
          (define (mark-group! group)
            (if (= (vector-ref marks group) generation)
                0
                (begin
                  (vector-set! marks group generation)
                  (vector-ref multiplicities group))))
          (define (drain-terminal-chain state)
            (let loop
                ((terminal
                  (if (null? (relevance-text-node-outputs state))
                      (relevance-text-node-output-link state)
                      state))
                 (score 0))
              (cond
               ((not terminal) score)
               ((= (relevance-text-node-generation terminal) generation)
                score)
               (else
                (set-relevance-text-node-generation!
                 terminal generation)
                (let outputs
                    ((rest (relevance-text-node-outputs terminal))
                     (next-score score))
                  (if (null? rest)
                      (loop
                       (relevance-text-node-output-link terminal)
                       next-score)
                      (outputs
                       (cdr rest)
                       (+ next-score (mark-group! (car rest))))))))))
          (if (or (not text-root) (= count 0))
              key-score
              (let ((state text-root)
                    (score
                     (+ key-score
                        (drain-terminal-chain text-root))))
                (string-for-each
                 (lambda (character)
                   (set! state
                         (relevance-text-next
                          text-root state character))
                   (set! score
                         (+ score (drain-terminal-chain state))))
                 (record-search-text record))
                score)))))

    (define (candidate-field candidate name)
      "Return CANDIDATE field NAME."
      (field-value candidate name))

    (define (candidate-score candidate)
      "Return CANDIDATE's score."
      (candidate-field candidate 'score))

    (define (candidate-id candidate)
      "Return CANDIDATE's id."
      (candidate-field candidate 'id))

    (define (candidate-id-tie-key candidate)
      "Return CANDIDATE's detached append-time id descriptor."
      (candidate-field candidate '%prepared-id-key))

    (define (ranked-entry-score> left right)
      "Return #t when ranked entry LEFT should sort before RIGHT."
      (let ((left-score (ranked-candidate-entry-score left))
            (right-score (ranked-candidate-entry-score right)))
        (cond
         ((> left-score right-score) #t)
         ((< left-score right-score) #f)
         (else
          (let ((left-key (ranked-candidate-entry-tie-key left))
                (right-key (ranked-candidate-entry-tie-key right)))
            (let ((left-name
                   (memory-index-key-symbol-name left-key))
                  (right-name
                   (memory-index-key-symbol-name right-key)))
              (cond
               ((and left-name right-name)
                (string<? left-name right-name))
               (left-name #t)
               (right-name #f)
               (else (memory-index-key<? left-key right-key)))))))))

    (define (ranked-entry-ordinal<? left right)
      "Return #t when ranked entry LEFT precedes RIGHT in projection order."
      (< (ranked-candidate-entry-ordinal left)
         (ranked-candidate-entry-ordinal right)))

    (define (ranked-entry-total> left right)
      "Return the strict total selection order for LEFT and RIGHT."
      (cond
       ((ranked-entry-score> left right) #t)
       ((ranked-entry-score> right left) #f)
       (else (ranked-entry-ordinal<? left right))))

    (define (ranked-entry-worse? left right)
      "Return #t when LEFT ranks after RIGHT."
      (ranked-entry-total> right left))

    (define (split-sort-values values)
      "Split VALUES near its midpoint while preserving order."
      (let loop ((slow values) (fast values) (left '()))
        (if (or (null? fast) (null? (cdr fast)))
            (cons (reverse left) slow)
            (loop (cdr slow)
                  (cddr fast)
                  (cons (car slow) left)))))

    (define (prepend-reversed reversed tail)
      "Prepend REVERSED in forward order to TAIL."
      (let loop ((rest reversed) (result tail))
        (if (null? rest)
            result
            (loop (cdr rest) (cons (car rest) result)))))

    (define (merge-sorted before? left right)
      "Stably merge LEFT and RIGHT according to BEFORE?."
      (let loop ((left left) (right right) (merged '()))
        (cond
         ((null? left) (prepend-reversed merged right))
         ((null? right) (prepend-reversed merged left))
         ((before? (car right) (car left))
          (loop left (cdr right) (cons (car right) merged)))
         (else
          (loop (cdr left) right (cons (car left) merged))))))

    (define (stable-sort before? values)
      "Return VALUES stably sorted according to BEFORE?."
      (if (or (null? values) (null? (cdr values)))
          values
          (let ((halves (split-sort-values values)))
            (merge-sorted
             before?
             (stable-sort before? (car halves))
             (stable-sort before? (cdr halves))))))

    (define (select-ranked-entries candidates cutoff limit)
      "Return the best LIMIT eligible candidates in exact rank order."
      (let* ((capacity (min limit (length candidates)))
             (heap (make-vector capacity #f))
             (size 0))
        (define (swap! left right)
          (let ((value (vector-ref heap left)))
            (vector-set! heap left (vector-ref heap right))
            (vector-set! heap right value)))
        (define (sift-up! start)
          (let loop ((index start))
            (if (> index 0)
                (let ((parent (quotient (- index 1) 2)))
                  (if (ranked-entry-worse?
                       (vector-ref heap index)
                       (vector-ref heap parent))
                      (begin (swap! index parent) (loop parent)))))))
        (define (sift-down! start)
          (let loop ((index start))
            (let ((left (+ (* index 2) 1)))
              (if (< left size)
                  (let* ((right (+ left 1))
                         (worse
                          (if (and (< right size)
                                   (ranked-entry-worse?
                                    (vector-ref heap right)
                                    (vector-ref heap left)))
                              right
                              left)))
                    (if (ranked-entry-worse?
                         (vector-ref heap worse)
                         (vector-ref heap index))
                        (begin (swap! worse index) (loop worse))))))))
        (define (consider! entry)
          (cond
           ((= capacity 0) #f)
           ((< size capacity)
            (vector-set! heap size entry)
            (set! size (+ size 1))
            (sift-up! (- size 1)))
           ((ranked-entry-total> entry (vector-ref heap 0))
            (vector-set! heap 0 entry)
            (sift-down! 0))))
        (let loop ((rest candidates) (ordinal 0))
          (if (not (null? rest))
              (let ((candidate (car rest)))
                (if (and
                     (eq? (candidate-field candidate 'status) 'ranked)
                     (>= (candidate-score candidate) cutoff))
                    (consider!
                     (make-ranked-candidate-entry
                      ordinal
                      candidate
                      (candidate-score candidate)
                      (candidate-id-tie-key candidate))))
                (loop (cdr rest) (+ ordinal 1)))))
        (let collect ((index 0) (selected '()))
          (if (= index size)
              (stable-sort ranked-entry-total> selected)
              (collect (+ index 1)
                       (cons (vector-ref heap index) selected))))))

    (define (make-filtered-candidate record reason)
      "Return a filtered memory-selection candidate for RECORD."
      (list 'memory-candidate
            (list 'id (memory-record-id record))
            (list 'status 'filtered)
            (list 'reason reason)
            (list 'score 'not-ranked)
            (list 'subscores '())))

    (define (make-ranked-candidate
             terms
             weights
             logical-clock
             record
             sidecar
             ordered-key
             access-sequence)
      "Return a ranked memory-selection candidate for RECORD."
      (let* ((recency
              (recency-score logical-clock record access-sequence))
             (importance (importance-score record))
             (relevance (relevance-score terms record sidecar))
             (score (+ (* (weight-ref weights 'recency 1) recency)
                       (* (weight-ref weights 'importance 1) importance)
                       (* (weight-ref weights 'relevance 1) relevance))))
        (list 'memory-candidate
              (list 'id (memory-record-id record))
              (list 'record record)
              (list 'status 'ranked)
              (list 'score score)
              (list 'subscores
                    (list (list 'recency recency)
                          (list 'importance importance)
                          (list 'relevance relevance)))
              (list '%prepared-id-key ordered-key))))

    (define (finalize-candidate candidate selected?)
      "Mark ranked CANDIDATE as selected or below-cutoff."
      (if (not (eq? (candidate-field candidate 'status) 'ranked))
          candidate
          (append
           (list 'memory-candidate
                 (list 'id (candidate-id candidate))
                 (list 'record (candidate-field candidate 'record))
                 (list 'status
                       (if selected? 'selected 'not-selected))
                 (list 'score (candidate-score candidate))
                 (list 'subscores (candidate-field candidate 'subscores)))
           (if selected?
               '()
               (list (list 'reason 'below-cutoff-or-limit))))))

    (define (selected-ordinal-membership selected count)
      "Return a COUNT-slot bitmap for ranked SELECTED entries."
      (let ((membership (make-vector count #f)))
        (let loop ((rest selected))
          (if (null? rest)
              membership
              (begin
                (vector-set!
                 membership
                 (ranked-candidate-entry-ordinal (car rest))
                 #t)
                (loop (cdr rest)))))))

    (define (finalize-candidates candidates selected-membership)
      "Finalize CANDIDATES using SELECTED-MEMBERSHIP in live order."
      (let loop ((rest candidates)
                 (ordinal 0)
                 (finalized '()))
        (if (null? rest)
            (reverse finalized)
            (loop
             (cdr rest)
             (+ ordinal 1)
             (cons
              (finalize-candidate
               (car rest) (vector-ref selected-membership ordinal))
              finalized)))))

    (define (memory-store-select store query-projection policy context)
      "Return a deterministic receipt from detached QUERY-PROJECTION."
      #((parameters
         (store (type consent-memory-store)
          (description "Memory store to inspect."))
         (query-projection (type vector)
          (description
           "Original query plus source-prepared relevance projections."))
         (policy (type retrieval-policy)
          (description "Printable retrieval policy record."))
         (context (type retrieval-context)
          (description "Request scope, trust, and logical-clock context.")))
        (returns (type memory-selection)
         (description
          ("A replayable selection receipt with selected records,"
            "per-candidate scores, filter reasons, and the cutoff.")))
        (effects state-read error))
      (if (not (and (vector? query-projection)
                    (= (vector-length query-projection) 2)
                    (vector? (vector-ref query-projection 1))))
          (error "memory query received invalid select projection"
                 query-projection))
      (let* ((query (vector-ref query-projection 0))
             (term-projections (vector-ref query-projection 1))
             (live (all-live-entries store))
             (terms (normalize-query-terms store term-projections))
             (weights (policy-field policy 'weights '()))
             (cutoff (numeric-value (policy-field policy 'cutoff 0)))
             (raw-limit
              (integer-value (policy-field policy 'limit (length live))))
             (limit
              (if (< raw-limit 0)
                  (error
                   "memory selection limit must be nonnegative" raw-limit)
                  raw-limit))
             (context-scope
              (normalize-scope (context-field context 'scope 'project)))
             (trust (context-field context 'trust 'local))
             (logical-clock
              (integer-value
               (context-field context
                              'logical-clock
                              (store-next-id store))))
             (allowed-scopes
              (normalize-allowed-scopes
               (context-field
                context 'allowed-scopes (list context-scope))))
             (candidates
              (map
               (lambda (entry)
                 (let ((record (vector-ref entry 1))
                       (sidecar (vector-ref entry 2))
                       (ordered-key
                        (memory-key-sidecar-id-key
                         (vector-ref entry 2)))
                       (access-sequence (vector-ref entry 3)))
                   (cond
                    ((not (sidecar-scope-allowed?
                           sidecar allowed-scopes))
                     (make-filtered-candidate record 'scope-mismatch))
                    ((and (lower-trust? trust)
                          (redaction-sensitive? sidecar))
                     (make-filtered-candidate
                      record 'redaction-or-local-only))
                    (else
                     (make-ranked-candidate
                      terms
                      weights
                      logical-clock
                      record
                      sidecar
                      ordered-key
                      access-sequence)))))
               live))
             (selected-entries
              (select-ranked-entries candidates cutoff limit))
             (selected
              (map ranked-candidate-entry-candidate selected-entries))
             (selected-membership
              (selected-ordinal-membership
               selected-entries (length candidates)))
             (final-candidates
              (finalize-candidates candidates selected-membership)))
        (list 'memory-selection
              (list 'query query)
              (list 'policy policy)
              (list 'context context)
              (list 'cutoff cutoff)
              (list 'selected (map candidate-id selected))
              (list 'records
                    (map (lambda (candidate)
                           (candidate-field candidate 'record))
                         selected))
              (list 'candidates final-candidates))))


    (define (memory-query-find records live-projections scope projection)
      "Search canonical RECORDS in SCOPE from detached PROJECTION."
      #((parameters
         (records (type (list-of list))
          (description "Canonical memory record datums to inspect."))
         (live-projections (type (list-of vector))
          (description
           "Aligned sealed sidecar and access-sequence projections."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (projection (type vector)
          (description "Source-prepared text, key, or match projection.")))
        (returns (type (list-of list))
         (description "Matching canonical memory record datums in SCOPE."))
        (effects allocation error))
      (memory-store-find
       (make-memory-query-view records live-projections 0)
       scope
       projection))

    (define (memory-query-by-tag records live-projections scope tag-key)
      "Return live canonical RECORDS in SCOPE carrying TAG-KEY."
      #((parameters
         (records (type (list-of list))
          (description "Canonical memory record datums to inspect."))
         (live-projections (type (list-of vector))
          (description
           "Aligned sealed sidecar and access-sequence projections."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (tag-key (type vector)
          (description "Source-prepared scope-qualified tag descriptor.")))
        (returns (type (list-of list))
         (description "Canonical memory record datums carrying TAG."))
        (effects allocation error))
      (memory-store-by-tag
       (make-memory-query-view records live-projections 0)
       scope
       tag-key))

    (define (memory-query-recent records live-projections scope count)
      "Return at most COUNT recent live canonical RECORDS in SCOPE."
      #((parameters
         (records (type (list-of list))
          (description "Canonical memory record datums to inspect."))
         (live-projections (type (list-of vector))
          (description
           "Aligned sealed sidecar and access-sequence projections."))
         (scope (type symbol)
          (description "Memory scope symbol."))
         (count (type exact-integer)
          (description
           "Result limit; a nonpositive exact integer returns no records.")))
        (returns (type (list-of list))
         (description "At most COUNT recent canonical records in SCOPE."))
        (effects allocation error))
      (memory-store-recent
       (make-memory-query-view records live-projections 0)
       scope
       count))

    (define (memory-query-select
             records
             live-projections
             next-id
             query-projection
             policy
             context)
      "Return a deterministic receipt over canonical RECORDS."
      #((parameters
         (records (type (list-of list))
          (description "Canonical memory record datums to inspect."))
         (live-projections (type (list-of vector))
          (description
           "Aligned sealed sidecar and access-sequence projections."))
         (next-id (type exact-integer)
          (description "Current store next-id clock."))
         (query-projection (type vector)
          (description
           "Original query plus source-prepared relevance projections."))
         (policy (type retrieval-policy)
          (description "Printable retrieval policy record."))
         (context (type retrieval-context)
          (description "Request scope, trust, and logical-clock context.")))
        (returns (type memory-selection)
         (description
          ("A replayable selection receipt with selected records,"
            "per-candidate scores, filter reasons, and the cutoff.")))
        (effects allocation error))
      (memory-store-select
       (make-memory-query-view records live-projections next-id)
       query-projection
       policy
       context))))
