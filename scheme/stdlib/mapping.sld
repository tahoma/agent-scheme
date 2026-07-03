;;; SRFI 146 ordered mapping library support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2016 Marc Nieper-Wißkirchen
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib mapping)' as a portable R7RS adaptation of the official
;;; SRFI 146 ordered mapping source:
;;; https://github.com/scheme-requests-for-implementation/srfi-146.
;;; Local patches rename the source library, inline the upstream body file for
;;; Consent Scheme's source-library loader, adapt imports to local stdlib
;;; libraries, document exported procedures with Consent Scheme metadata, and
;;; keep `(scheme mapping)', `(srfi 146)', and `(srfi srfi-146)' as registry
;;; aliases. The SRFI 146 hash mapping variant is intentionally out of scope.

(define-library (stdlib mapping)
  (export mapping mapping-unfold
          mapping/ordered mapping-unfold/ordered
          mapping? mapping-contains? mapping-empty? mapping-disjoint?
          mapping-ref mapping-ref/default mapping-key-comparator
          mapping-adjoin mapping-adjoin!
          mapping-set mapping-set!
          mapping-replace mapping-replace!
          mapping-delete mapping-delete! mapping-delete-all mapping-delete-all!
          mapping-intern mapping-intern!
          mapping-update mapping-update! mapping-update/default
          mapping-update!/default
          mapping-pop mapping-pop!
          mapping-search mapping-search!
          mapping-size mapping-find mapping-count mapping-any? mapping-every?
          mapping-keys mapping-values mapping-entries
          mapping-map mapping-map->list mapping-for-each mapping-fold
          mapping-filter mapping-filter!
          mapping-remove mapping-remove!
          mapping-partition mapping-partition!
          mapping-copy mapping->alist alist->mapping alist->mapping!
          alist->mapping/ordered alist->mapping/ordered!
          mapping=? mapping<? mapping>? mapping<=? mapping>=?
          mapping-union mapping-intersection mapping-difference mapping-xor
          mapping-union! mapping-intersection! mapping-difference! mapping-xor!
          make-mapping-comparator
          mapping-comparator
          mapping-min-key mapping-max-key
          mapping-min-value mapping-max-value
          mapping-key-predecessor mapping-key-successor
          mapping-range= mapping-range< mapping-range> mapping-range<=
          mapping-range>=
          mapping-range=! mapping-range<! mapping-range>! mapping-range<=!
          mapping-range>=!
          mapping-split
          mapping-catenate mapping-catenate!
          mapping-map/monotone mapping-map/monotone!
          mapping-fold/reverse
          comparator?)
  (import (scheme base)
          (scheme case-lambda)
          (stdlib list)
          (stdlib receive)
          (stdlib comparator)
          (stdlib assume)
          (stdlib rbtree))
  (begin
    ;; Ordered mappings pair a key comparator with a red-black tree.
    (define-record-type <mapping>
      (%make-mapping comparator tree)
      raw-mapping?
      (comparator raw-mapping-key-comparator)
      (tree mapping-tree))

    (define (mapping? obj)
      "Return #t when OBJ is an ordered SRFI 146 mapping."
      #((parameters
         (obj (type any)
          (description "Candidate object to test.")))
        (returns (type boolean)
         (description "Whether OBJ is an ordered mapping."))
        (effects pure))
      (raw-mapping? obj))

    (define (mapping-key-comparator mapping)
      "Return MAPPING's key comparator."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type comparator)
         (description "Comparator used to compare keys in MAPPING."))
        (effects error))
      (assume (mapping? mapping))
      (raw-mapping-key-comparator mapping))

    (define (make-empty-mapping comparator)
      "Return an empty ordered mapping using COMPARATOR."
      (assume (comparator? comparator))
      (%make-mapping comparator (make-tree)))

    (define (mapping comparator . args)
      "Return a newly allocated ordered mapping initialized from ARGS."
      #((parameters
         (comparator (type comparator)
          (description "Comparator controlling the mapping keys."))
         (args (type list)
          (description "Alternating keys and values used to initialize the mapping.")))
        (returns (type mapping)
         (description "An ordered mapping containing the supplied associations."))
        (effects allocation error procedure-call))
      (assume (comparator? comparator))
      (mapping-unfold null?
                      (lambda (args)
                        (values (car args) (cadr args)))
                      cddr
                      args
                      comparator))

    (define (mapping-unfold stop? mapper successor seed comparator)
      "Return a mapping unfolded from SEED until STOP? holds."
      #((parameters
         (stop? (type procedure)
          (description "Predicate deciding when unfolding stops."))
         (mapper (type procedure)
          (description "Procedure returning a key and value from the seed."))
         (successor (type procedure)
          (description "Procedure returning the next seed."))
         (seed (type any)
          (description "Initial unfold seed."))
         (comparator (type comparator)
          (description "Comparator controlling the mapping keys.")))
        (returns (type mapping)
         (description "An ordered mapping built from the generated associations."))
        (effects allocation error procedure-call))
      (assume (procedure? stop?))
      (assume (procedure? mapper))
      (assume (procedure? successor))
      (assume (comparator? comparator))
      (let loop ((mapping (make-empty-mapping comparator))
                 (seed seed))
        (if (stop? seed)
            mapping
            (receive (key value)
                (mapper seed)
              (loop (mapping-adjoin mapping key value)
                    (successor seed))))))

    ;; SRFI 146 ordered constructor aliases.
    (define mapping/ordered mapping)

    ;; SRFI 146 ordered unfold constructor alias.
    (define mapping-unfold/ordered mapping-unfold)

    (define (mapping-empty? mapping)
      "Return #t when MAPPING has no associations."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type boolean)
         (description "Whether MAPPING is empty."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (not (mapping-any? (lambda (key value) #t) mapping)))

    (define (mapping-contains? mapping key)
      "Return #t when MAPPING contains KEY."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect."))
         (key (type any)
          (description "Key to search for.")))
        (returns (type boolean)
         (description "Whether KEY is present in MAPPING."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (call/cc
       (lambda (return)
         (mapping-search mapping
                         key
                         (lambda (insert ignore)
                           (return #f))
                         (lambda (key value update remove)
                           (return #t))))))

    (define (mapping-disjoint? mapping1 mapping2)
      "Return #t when MAPPING1 and MAPPING2 have no keys in common."
      #((parameters
         (mapping1 (type mapping)
          (description "First ordered mapping to compare."))
         (mapping2 (type mapping)
          (description "Second ordered mapping to compare.")))
        (returns (type boolean)
         (description "Whether the mappings share no key."))
        (effects error procedure-call))
      (assume (mapping? mapping1))
      (assume (mapping? mapping2))
      (call/cc
       (lambda (return)
         (mapping-for-each (lambda (key value)
                             (when (mapping-contains? mapping2 key)
                               (return #f)))
                           mapping1)
         #t)))

    (define (mapping-ref mapping key . maybe-failure+success)
      "Return KEY's value in MAPPING, or invoke failure and success handlers."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to search."))
         (key (type any)
          (description "Key to look up."))
         (maybe-failure+success (type list)
          (description "Optional failure thunk and success procedure.")))
        (returns (type any)
         (description "Stored value or the result of a supplied handler."))
        (effects error procedure-call))
      (apply
       (case-lambda
        ((mapping key)
         (assume (mapping? mapping))
         (mapping-ref mapping key
                      (lambda ()
                        (error "mapping-ref: key not in mapping" key))))
        ((mapping key failure)
         (assume (mapping? mapping))
         (assume (procedure? failure))
         (mapping-ref mapping key failure (lambda (value) value)))
        ((mapping key failure success)
         (assume (mapping? mapping))
         (assume (procedure? failure))
         (assume (procedure? success))
         ((call/cc
           (lambda (return-thunk)
             (mapping-search mapping
                             key
                             (lambda (insert ignore)
                               (return-thunk failure))
                             (lambda (key value update remove)
                               (return-thunk
                                (lambda () (success value))))))))))
       mapping
       key
       maybe-failure+success))

    (define (mapping-ref/default mapping key default)
      "Return KEY's value in MAPPING, or DEFAULT when absent."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to search."))
         (key (type any)
          (description "Key to look up."))
         (default (type any)
          (description "Value returned when KEY is absent.")))
        (returns (type any)
         (description "Stored value or DEFAULT."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (mapping-ref mapping key (lambda () default)))

    (define (mapping-adjoin mapping . args)
      "Return MAPPING with absent ARGS associations adjoined."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to extend."))
         (args (type list)
          (description "Alternating keys and values to adjoin when absent.")))
        (returns (type mapping)
         (description "Mapping containing original and newly absent associations."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let loop ((args args)
                 (mapping mapping))
        (if (null? args)
            mapping
            (receive (mapping value)
                (mapping-intern mapping (car args) (lambda () (cadr args)))
              (loop (cddr args) mapping)))))

    ;; Linear-update adjoin is pure in this portable implementation.
    (define mapping-adjoin! mapping-adjoin)

    (define (mapping-set mapping . args)
      "Return MAPPING with ARGS associations inserted or replaced."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (args (type list)
          (description "Alternating keys and values to set.")))
        (returns (type mapping)
         (description "Mapping with the supplied associations set."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let loop ((args args)
                 (mapping mapping))
        (if (null? args)
            mapping
            (receive (mapping)
                (mapping-update mapping
                                (car args)
                                (lambda (value) (cadr args))
                                (lambda () #f))
              (loop (cddr args) mapping)))))

    ;; Linear-update set is pure in this portable implementation.
    (define mapping-set! mapping-set)

    (define (mapping-replace mapping key value)
      "Return MAPPING with KEY replaced by VALUE when KEY is present."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (key (type any)
          (description "Key whose association may be replaced."))
         (value (type any)
          (description "Replacement value.")))
        (returns (type mapping)
         (description "Mapping with KEY replaced when it was already present."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (receive (mapping obj)
          (mapping-search mapping
                          key
                          (lambda (insert ignore)
                            (ignore #f))
                          (lambda (old-key old-value update remove)
                            (update key value #f)))
        mapping))

    ;; Linear-update replace is pure in this portable implementation.
    (define mapping-replace! mapping-replace)

    (define (mapping-delete mapping . keys)
      "Return MAPPING without any associations for KEYS."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (keys (type list)
          (description "Keys whose associations should be removed.")))
        (returns (type mapping)
         (description "Mapping without the supplied keys."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (mapping-delete-all mapping keys))

    ;; Linear-update delete is pure in this portable implementation.
    (define mapping-delete! mapping-delete)

    (define (mapping-delete-all mapping keys)
      "Return MAPPING without any associations for KEYS."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (keys (type list)
          (description "List of keys whose associations should be removed.")))
        (returns (type mapping)
         (description "Mapping without the supplied keys."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (assume (list? keys))
      (fold (lambda (key mapping)
              (receive (mapping obj)
                  (mapping-search mapping
                                  key
                                  (lambda (insert ignore)
                                    (ignore #f))
                                  (lambda (old-key old-value update remove)
                                    (remove #f)))
                mapping))
            mapping
            keys))

    ;; Linear-update delete-all is pure in this portable implementation.
    (define mapping-delete-all! mapping-delete-all)

    (define (mapping-intern mapping key failure)
      "Return MAPPING and KEY's value, inserting FAILURE's value when absent."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to search or extend."))
         (key (type any)
          (description "Key to intern."))
         (failure (type procedure)
          (description "Thunk producing a value when KEY is absent.")))
        (returns (type any)
         (description "Two values: resulting mapping and KEY's value."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (assume (procedure? failure))
      (call/cc
       (lambda (return)
         (mapping-search mapping
                         key
                         (lambda (insert ignore)
                           (receive (value)
                               (failure)
                             (insert value value)))
                         (lambda (old-key old-value update remove)
                           (return mapping old-value))))))

    ;; Linear-update intern is pure in this portable implementation.
    (define mapping-intern! mapping-intern)

    (define (mapping-update mapping key updater . maybe-failure+success)
      "Return MAPPING with KEY's value transformed by UPDATER."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (key (type any)
          (description "Key whose value is updated."))
         (updater (type procedure)
          (description "Procedure applied to the current or fallback value."))
         (maybe-failure+success (type list)
          (description "Optional failure thunk and success procedure.")))
        (returns (type mapping)
         (description "Mapping with KEY updated."))
        (effects allocation error procedure-call))
      (apply
       (case-lambda
        ((mapping key updater)
         (mapping-update mapping
                         key
                         updater
                         (lambda ()
                           (error "mapping-update: key not found in mapping"
                                  key))))
        ((mapping key updater failure)
         (mapping-update mapping key updater failure (lambda (value) value)))
        ((mapping key updater failure success)
         (assume (mapping? mapping))
         (assume (procedure? updater))
         (assume (procedure? failure))
         (assume (procedure? success))
         (receive (mapping obj)
             (mapping-search mapping
                             key
                             (lambda (insert ignore)
                               (insert (updater (failure)) #f))
                             (lambda (old-key old-value update remove)
                               (update key
                                       (updater (success old-value))
                                       #f)))
           mapping)))
       mapping
       key
       updater
       maybe-failure+success))

    ;; Linear-update update is pure in this portable implementation.
    (define mapping-update! mapping-update)

    (define (mapping-update/default mapping key updater default)
      "Return MAPPING after updating KEY with DEFAULT as the absent value."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (key (type any)
          (description "Key whose value is updated."))
         (updater (type procedure)
          (description "Procedure applied to the current or default value."))
         (default (type any)
          (description "Value supplied to UPDATER when KEY is absent.")))
        (returns (type mapping)
         (description "Mapping with KEY updated."))
        (effects allocation error procedure-call))
      (mapping-update mapping key updater (lambda () default)))

    ;; Linear-update update/default is pure in this portable implementation.
    (define mapping-update!/default mapping-update/default)

    (define (mapping-pop mapping . maybe-failure)
      "Return MAPPING without its least association plus that key and value."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to pop."))
         (maybe-failure (type list)
          (description "Optional failure thunk for empty mappings.")))
        (returns (type any)
         (description
          "Three values on success: new mapping, minimum key, and value."))
        (effects allocation error procedure-call))
      (apply
       (case-lambda
        ((mapping)
         (mapping-pop mapping
                      (lambda ()
                        (error "mapping-pop: mapping has no association"))))
        ((mapping failure)
         (assume (mapping? mapping))
         (assume (procedure? failure))
         ((call/cc
           (lambda (return-thunk)
             (receive (key value)
                 (mapping-find (lambda (key value) #t)
                               mapping
                               (lambda () (return-thunk failure)))
               (lambda ()
                 (values (mapping-delete mapping key) key value))))))))
       mapping
       maybe-failure))

    ;; Linear-update pop is pure in this portable implementation.
    (define mapping-pop! mapping-pop)

    (define (mapping-search mapping key failure success)
      "Search MAPPING for KEY and return an edited mapping plus callback result."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to search."))
         (key (type any)
          (description "Search key."))
         (failure (type procedure)
          (description "Procedure receiving insert and ignore continuations."))
         (success (type procedure)
          (description
           "Procedure receiving key, value, update, and remove continuations.")))
        (returns (type any)
         (description "Two values: the edited mapping and callback result."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (assume (procedure? failure))
      (assume (procedure? success))
      (call/cc
       (lambda (return)
         (let*-values (((comparator)
                        (mapping-key-comparator mapping))
                       ((tree obj)
                        (tree-search comparator
                                     (mapping-tree mapping)
                                     key
                                     (lambda (insert ignore)
                                       (failure
                                        (lambda (value obj)
                                          (insert key value obj))
                                        (lambda (obj)
                                          (return mapping obj))))
                                     success)))
           (values (%make-mapping comparator tree)
                   obj)))))

    ;; Linear-update search is pure in this portable implementation.
    (define mapping-search! mapping-search)

    (define (mapping-size mapping)
      "Return the number of associations in MAPPING."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Association count."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (mapping-count (lambda (key value) #t) mapping))

    (define (mapping-find predicate mapping failure)
      "Return the first association satisfying PREDICATE, or call FAILURE."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to search."))
         (failure (type procedure)
          (description "Thunk called when no association matches.")))
        (returns (type any)
         (description "Matching key and value as values, or FAILURE's result."))
        (effects error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (assume (procedure? failure))
      (call/cc
       (lambda (return)
         (mapping-for-each (lambda (key value)
                             (when (predicate key value)
                               (return key value)))
                           mapping)
         (failure))))

    (define (mapping-count predicate mapping)
      "Return the count of associations satisfying PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type exact-non-negative-integer)
         (description "Number of matching associations."))
        (effects error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (mapping-fold (lambda (key value count)
                      (if (predicate key value)
                          (+ 1 count)
                          count))
                    0
                    mapping))

    (define (mapping-any? predicate mapping)
      "Return #t when any association in MAPPING satisfies PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type boolean)
         (description "Whether at least one association matches."))
        (effects error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (call/cc
       (lambda (return)
         (mapping-for-each (lambda (key value)
                             (when (predicate key value)
                               (return #t)))
                           mapping)
         #f)))

    (define (mapping-every? predicate mapping)
      "Return #t when every association in MAPPING satisfies PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type boolean)
         (description "Whether every association matches."))
        (effects error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (not (mapping-any? (lambda (key value)
                           (not (predicate key value)))
                         mapping)))

    (define (mapping-keys mapping)
      "Return MAPPING's keys in comparator order."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type list)
         (description "Keys in ascending order."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (mapping-fold/reverse (lambda (key value keys)
                              (cons key keys))
                            '()
                            mapping))

    (define (mapping-values mapping)
      "Return MAPPING's values in key order."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type list)
         (description "Values in ascending key order."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (mapping-fold/reverse (lambda (key value values)
                              (cons value values))
                            '()
                            mapping))

    (define (mapping-entries mapping)
      "Return MAPPING's keys and values as two ordered lists."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type any)
         (description "Two values: ordered keys and corresponding values."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (values (mapping-keys mapping)
              (mapping-values mapping)))

    (define (mapping-map proc comparator mapping)
      "Return a mapping of PROC over MAPPING using COMPARATOR for new keys."
      #((parameters
         (proc (type procedure)
          (description "Procedure accepting a key and value and returning two values."))
         (comparator (type comparator)
          (description "Comparator controlling the result keys."))
         (mapping (type mapping)
          (description "Ordered mapping to transform.")))
        (returns (type mapping)
         (description "Transformed ordered mapping."))
        (effects allocation error procedure-call))
      (assume (procedure? proc))
      (assume (comparator? comparator))
      (assume (mapping? mapping))
      (mapping-fold (lambda (key value mapping)
                      (receive (key value)
                          (proc key value)
                        (mapping-set mapping key value)))
                    (make-empty-mapping comparator)
                    mapping))

    (define (mapping-for-each proc mapping)
      "Call PROC on each association in MAPPING in key order."
      #((parameters
         (proc (type procedure)
          (description "Procedure called with each key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to traverse.")))
        (returns (type any)
         (description "Unspecified value."))
        (effects error procedure-call))
      (assume (procedure? proc))
      (assume (mapping? mapping))
      (tree-for-each proc (mapping-tree mapping)))

    (define (mapping-fold proc acc mapping)
      "Fold PROC over MAPPING from lowest key to highest key."
      #((parameters
         (proc (type procedure)
          (description "Procedure called as (proc key value accumulator)."))
         (acc (type any)
          (description "Initial accumulator."))
         (mapping (type mapping)
          (description "Ordered mapping to fold.")))
        (returns (type any)
         (description "Final accumulator."))
        (effects error procedure-call))
      (assume (procedure? proc))
      (assume (mapping? mapping))
      (tree-fold proc acc (mapping-tree mapping)))

    (define (mapping-map->list proc mapping)
      "Return a list of PROC results over MAPPING in key order."
      #((parameters
         (proc (type procedure)
          (description "Procedure called with each key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to traverse.")))
        (returns (type list)
         (description "List of procedure results in key order."))
        (effects allocation error procedure-call))
      (assume (procedure? proc))
      (assume (mapping? mapping))
      (mapping-fold/reverse (lambda (key value lst)
                              (cons (proc key value) lst))
                            '()
                            mapping))

    (define (mapping-filter predicate mapping)
      "Return associations in MAPPING that satisfy PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to filter.")))
        (returns (type mapping)
         (description "Mapping containing the matching associations."))
        (effects allocation error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (mapping-fold (lambda (key value mapping)
                      (if (predicate key value)
                          (mapping-set mapping key value)
                          mapping))
                    (make-empty-mapping (mapping-key-comparator mapping))
                    mapping))

    ;; Linear-update filter is pure in this portable implementation.
    (define mapping-filter! mapping-filter)

    (define (mapping-remove predicate mapping)
      "Return associations in MAPPING that do not satisfy PREDICATE."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to filter.")))
        (returns (type mapping)
         (description "Mapping containing the non-matching associations."))
        (effects allocation error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (mapping-filter (lambda (key value)
                        (not (predicate key value)))
                      mapping))

    ;; Linear-update remove is pure in this portable implementation.
    (define mapping-remove! mapping-remove)

    (define (mapping-partition predicate mapping)
      "Partition MAPPING by PREDICATE and return matching and removed mappings."
      #((parameters
         (predicate (type procedure)
          (description "Procedure accepting a key and value."))
         (mapping (type mapping)
          (description "Ordered mapping to partition.")))
        (returns (type any)
         (description "Two values: matching mapping and non-matching mapping."))
        (effects allocation error procedure-call))
      (assume (procedure? predicate))
      (assume (mapping? mapping))
      (values (mapping-filter predicate mapping)
              (mapping-remove predicate mapping)))

    ;; Linear-update partition is pure in this portable implementation.
    (define mapping-partition! mapping-partition)

    (define (mapping-copy mapping)
      "Return a copy of MAPPING."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to copy.")))
        (returns (type mapping)
         (description "A mapping with the same associations."))
        (effects error))
      (assume (mapping? mapping))
      mapping)

    (define (mapping->alist mapping)
      "Return MAPPING as an alist in key order."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to convert.")))
        (returns (type list)
         (description "Association list in ascending key order."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (reverse
       (mapping-fold (lambda (key value alist)
                       (cons (cons key value) alist))
                     '()
                     mapping)))

    (define (alist->mapping comparator alist)
      "Return an ordered mapping containing ALIST associations."
      #((parameters
         (comparator (type comparator)
          (description "Comparator controlling the mapping keys."))
         (alist (type list)
          (description "Association list to convert.")))
        (returns (type mapping)
         (description "Ordered mapping containing ALIST associations."))
        (effects allocation error procedure-call))
      (assume (comparator? comparator))
      (assume (list? alist))
      (mapping-unfold null?
                      (lambda (alist)
                        (let ((key (caar alist))
                              (value (cdar alist)))
                          (values key value)))
                      cdr
                      alist
                      comparator))

    (define (alist->mapping! mapping alist)
      "Return MAPPING with ALIST associations set."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to update."))
         (alist (type list)
          (description "Association list to add.")))
        (returns (type mapping)
         (description "Mapping with ALIST associations set."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (assume (list? alist))
      (fold (lambda (association mapping)
              (let ((key (car association))
                    (value (cdr association)))
                (mapping-set mapping key value)))
            mapping
            alist))

    ;; Ordered alist conversion alias.
    (define alist->mapping/ordered alist->mapping)

    ;; Linear-update ordered alist conversion alias.
    (define alist->mapping/ordered! alist->mapping!)

    (define (mapping=? comparator mapping . mappings)
      "Return #t when all MAPPINGS are equal by COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to compare values."))
         (mapping (type mapping)
          (description "First ordered mapping to compare."))
         (mappings (type list)
          (description "Additional ordered mappings to compare.")))
        (returns (type boolean)
         (description "Whether all adjacent mappings are equal."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (let loop ((left mapping) (rest mappings))
        (if (null? rest)
            #t
            (and (%mapping=? comparator left (car rest))
                 (loop (car rest) (cdr rest))))))

    (define (%mapping=? comparator mapping1 mapping2)
      "Return #t when MAPPING1 and MAPPING2 have the same associations."
      (and (eq? (mapping-key-comparator mapping1)
                (mapping-key-comparator mapping2))
           (%mapping<=? comparator mapping1 mapping2)
           (%mapping<=? comparator mapping2 mapping1)))

    (define (mapping<=? comparator mapping . mappings)
      "Return #t when each mapping is a submapping of the next."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to compare values."))
         (mapping (type mapping)
          (description "First ordered mapping to compare."))
         (mappings (type list)
          (description "Additional ordered mappings to compare.")))
        (returns (type boolean)
         (description "Whether each mapping is a submapping of the next."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (let loop ((left mapping) (rest mappings))
        (if (null? rest)
            #t
            (and (%mapping<=? comparator left (car rest))
                 (loop (car rest) (cdr rest))))))

    (define (%mapping<=? comparator mapping1 mapping2)
      "Return #t when MAPPING1 is a submapping of MAPPING2."
      (assume (comparator? comparator))
      (assume (mapping? mapping1))
      (assume (mapping? mapping2))
      (let ((less? (comparator-ordering-predicate
                    (mapping-key-comparator mapping1)))
            (equality-predicate (comparator-equality-predicate comparator))
            (gen1 (tree-generator (mapping-tree mapping1)))
            (gen2 (tree-generator (mapping-tree mapping2))))
        (let loop ((item1 (gen1))
                   (item2 (gen2)))
          (cond
           ((eof-object? item1) #t)
           ((eof-object? item2) #f)
           (else
            (let ((key1 (car item1))
                  (value1 (cadr item1))
                  (key2 (car item2))
                  (value2 (cadr item2)))
              (cond
               ((less? key1 key2) #f)
               ((less? key2 key1) (loop item1 (gen2)))
               ((equality-predicate value1 value2) (loop (gen1) (gen2)))
               (else #f))))))))

    (define (mapping>? comparator mapping . mappings)
      "Return #t when each mapping is a supermapping of the next."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to compare values."))
         (mapping (type mapping)
          (description "First ordered mapping to compare."))
         (mappings (type list)
          (description "Additional ordered mappings to compare.")))
        (returns (type boolean)
         (description "Whether each mapping is a supermapping of the next."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (let loop ((left mapping) (rest mappings))
        (if (null? rest)
            #t
            (and (%mapping>? comparator left (car rest))
                 (loop (car rest) (cdr rest))))))

    (define (%mapping>? comparator mapping1 mapping2)
      "Return #t when MAPPING1 is a supermapping of MAPPING2."
      (assume (comparator? comparator))
      (assume (mapping? mapping1))
      (assume (mapping? mapping2))
      (and (%mapping<=? comparator mapping2 mapping1)
           (not (%mapping<=? comparator mapping1 mapping2))))

    (define (mapping<? comparator mapping . mappings)
      "Return #t when each mapping is a proper submapping of the next."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to compare values."))
         (mapping (type mapping)
          (description "First ordered mapping to compare."))
         (mappings (type list)
          (description "Additional ordered mappings to compare.")))
        (returns (type boolean)
         (description "Whether each mapping is a proper submapping of the next."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (let loop ((left mapping) (rest mappings))
        (if (null? rest)
            #t
            (and (%mapping<? comparator left (car rest))
                 (loop (car rest) (cdr rest))))))

    (define (%mapping<? comparator mapping1 mapping2)
      "Return #t when MAPPING1 is a proper submapping of MAPPING2."
      (assume (comparator? comparator))
      (assume (mapping? mapping1))
      (assume (mapping? mapping2))
      (and (%mapping<=? comparator mapping1 mapping2)
           (not (%mapping<=? comparator mapping2 mapping1))))

    (define (mapping>=? comparator mapping . mappings)
      "Return #t when each mapping is a supermapping of the next."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used to compare values."))
         (mapping (type mapping)
          (description "First ordered mapping to compare."))
         (mappings (type list)
          (description "Additional ordered mappings to compare.")))
        (returns (type boolean)
         (description "Whether each mapping is a supermapping of the next."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (let loop ((left mapping) (rest mappings))
        (if (null? rest)
            #t
            (and (%mapping>=? comparator left (car rest))
                 (loop (car rest) (cdr rest))))))

    (define (%mapping>=? comparator mapping1 mapping2)
      "Return #t when MAPPING1 is a supermapping of or equal to MAPPING2."
      (assume (comparator? comparator))
      (assume (mapping? mapping1))
      (assume (mapping? mapping2))
      (%mapping<=? comparator mapping2 mapping1))

    (define (%mapping-union mapping1 mapping2)
      "Return the union of MAPPING1 and MAPPING2."
      (mapping-fold (lambda (key2 value2 mapping)
                      (receive (mapping obj)
                          (mapping-search mapping
                                          key2
                                          (lambda (insert ignore)
                                            (insert value2 #f))
                                          (lambda (key1 value1 update remove)
                                            (update key1 value1 #f)))
                        mapping))
                    mapping1
                    mapping2))

    (define (%mapping-intersection mapping1 mapping2)
      "Return the intersection of MAPPING1 and MAPPING2."
      (mapping-filter (lambda (key1 value1)
                        (mapping-contains? mapping2 key1))
                      mapping1))

    (define (%mapping-difference mapping1 mapping2)
      "Return MAPPING1 without MAPPING2's keys."
      (mapping-fold (lambda (key2 value2 mapping)
                      (receive (mapping obj)
                          (mapping-search mapping
                                          key2
                                          (lambda (insert ignore)
                                            (ignore #f))
                                          (lambda (key1 value1 update remove)
                                            (remove #f)))
                        mapping))
                    mapping1
                    mapping2))

    (define (%mapping-xor mapping1 mapping2)
      "Return the symmetric difference of MAPPING1 and MAPPING2."
      (mapping-fold (lambda (key2 value2 mapping)
                      (receive (mapping obj)
                          (mapping-search mapping
                                          key2
                                          (lambda (insert ignore)
                                            (insert value2 #f))
                                          (lambda (key1 value1 update remove)
                                            (remove #f)))
                        mapping))
                    mapping1
                    mapping2))

    (define (mapping-union mapping . mappings)
      "Return the union of MAPPING and MAPPINGS."
      #((parameters
         (mapping (type mapping)
          (description "First ordered mapping."))
         (mappings (type list)
          (description "Additional ordered mappings.")))
        (returns (type mapping)
         (description "Union mapping."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let loop ((result mapping) (rest mappings))
        (if (null? rest)
            result
            (begin
              (assume (mapping? (car rest)))
              (loop (%mapping-union result (car rest)) (cdr rest))))))

    ;; Linear-update union is pure in this portable implementation.
    (define mapping-union! mapping-union)

    (define (mapping-intersection mapping . mappings)
      "Return the intersection of MAPPING and MAPPINGS."
      #((parameters
         (mapping (type mapping)
          (description "First ordered mapping."))
         (mappings (type list)
          (description "Additional ordered mappings.")))
        (returns (type mapping)
         (description "Intersection mapping."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let loop ((result mapping) (rest mappings))
        (if (null? rest)
            result
            (begin
              (assume (mapping? (car rest)))
              (loop (%mapping-intersection result (car rest)) (cdr rest))))))

    ;; Linear-update intersection is pure in this portable implementation.
    (define mapping-intersection! mapping-intersection)

    (define (mapping-difference mapping . mappings)
      "Return MAPPING without keys from MAPPINGS."
      #((parameters
         (mapping (type mapping)
          (description "First ordered mapping."))
         (mappings (type list)
          (description "Ordered mappings whose keys are removed.")))
        (returns (type mapping)
         (description "Difference mapping."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let loop ((result mapping) (rest mappings))
        (if (null? rest)
            result
            (begin
              (assume (mapping? (car rest)))
              (loop (%mapping-difference result (car rest)) (cdr rest))))))

    ;; Linear-update difference is pure in this portable implementation.
    (define mapping-difference! mapping-difference)

    (define (mapping-xor mapping . mappings)
      "Return the symmetric difference of MAPPING and MAPPINGS."
      #((parameters
         (mapping (type mapping)
          (description "First ordered mapping."))
         (mappings (type list)
          (description "Additional ordered mappings.")))
        (returns (type mapping)
         (description "Symmetric-difference mapping."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let loop ((result mapping) (rest mappings))
        (if (null? rest)
            result
            (begin
              (assume (mapping? (car rest)))
              (loop (%mapping-xor result (car rest)) (cdr rest))))))

    ;; Linear-update xor is pure in this portable implementation.
    (define mapping-xor! mapping-xor)

    (define (mapping-min-key mapping)
      "Return the least key in MAPPING."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type any)
         (description "Least key."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (call/cc
       (lambda (return)
         (mapping-fold (lambda (key value acc)
                         (return key))
                       #f
                       mapping)
         (error "mapping-min-key: empty mapping"))))

    (define (mapping-max-key mapping)
      "Return the greatest key in MAPPING."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type any)
         (description "Greatest key."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (call/cc
       (lambda (return)
         (mapping-fold/reverse (lambda (key value acc)
                                 (return key))
                               #f
                               mapping)
         (error "mapping-max-key: empty mapping"))))

    (define (mapping-min-value mapping)
      "Return the value associated with MAPPING's least key."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type any)
         (description "Value associated with the least key."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (call/cc
       (lambda (return)
         (mapping-fold (lambda (key value acc)
                         (return value))
                       #f
                       mapping)
         (error "mapping-min-value: empty mapping"))))

    (define (mapping-max-value mapping)
      "Return the value associated with MAPPING's greatest key."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to inspect.")))
        (returns (type any)
         (description "Value associated with the greatest key."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (call/cc
       (lambda (return)
         (mapping-fold/reverse (lambda (key value acc)
                                 (return value))
                               #f
                               mapping)
         (error "mapping-max-value: empty mapping"))))

    (define (mapping-key-predecessor mapping obj failure)
      "Return the greatest key below OBJ in MAPPING, or call FAILURE."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to search."))
         (obj (type any)
          (description "Boundary key."))
         (failure (type procedure)
          (description "Thunk called when no predecessor exists.")))
        (returns (type any)
         (description "Predecessor key or FAILURE's result."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (assume (procedure? failure))
      (tree-key-predecessor (mapping-key-comparator mapping)
                            (mapping-tree mapping)
                            obj
                            failure))

    (define (mapping-key-successor mapping obj failure)
      "Return the least key above OBJ in MAPPING, or call FAILURE."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to search."))
         (obj (type any)
          (description "Boundary key."))
         (failure (type procedure)
          (description "Thunk called when no successor exists.")))
        (returns (type any)
         (description "Successor key or FAILURE's result."))
        (effects error procedure-call))
      (assume (mapping? mapping))
      (assume (procedure? failure))
      (tree-key-successor (mapping-key-comparator mapping)
                          (mapping-tree mapping)
                          obj
                          failure))

    (define (mapping-range= mapping obj)
      "Return MAPPING's association whose key equals OBJ."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type mapping)
         (description "Mapping containing the equal-key association."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let ((comparator (mapping-key-comparator mapping)))
        (receive (tree< tree<= tree= tree>= tree>)
            (tree-split comparator (mapping-tree mapping) obj)
          (%make-mapping comparator tree=))))

    (define (mapping-range< mapping obj)
      "Return associations in MAPPING whose keys are below OBJ."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type mapping)
         (description "Mapping containing keys below OBJ."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let ((comparator (mapping-key-comparator mapping)))
        (receive (tree< tree<= tree= tree>= tree>)
            (tree-split comparator (mapping-tree mapping) obj)
          (%make-mapping comparator tree<))))

    (define (mapping-range<= mapping obj)
      "Return associations in MAPPING whose keys are at or below OBJ."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type mapping)
         (description "Mapping containing keys at or below OBJ."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let ((comparator (mapping-key-comparator mapping)))
        (receive (tree< tree<= tree= tree>= tree>)
            (tree-split comparator (mapping-tree mapping) obj)
          (%make-mapping comparator tree<=))))

    (define (mapping-range> mapping obj)
      "Return associations in MAPPING whose keys are above OBJ."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type mapping)
         (description "Mapping containing keys above OBJ."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let ((comparator (mapping-key-comparator mapping)))
        (receive (tree< tree<= tree= tree>= tree>)
            (tree-split comparator (mapping-tree mapping) obj)
          (%make-mapping comparator tree>))))

    (define (mapping-range>= mapping obj)
      "Return associations in MAPPING whose keys are at or above OBJ."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type mapping)
         (description "Mapping containing keys at or above OBJ."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let ((comparator (mapping-key-comparator mapping)))
        (receive (tree< tree<= tree= tree>= tree>)
            (tree-split comparator (mapping-tree mapping) obj)
          (%make-mapping comparator tree>=))))

    ;; Linear-update range= is pure in this portable implementation.
    (define mapping-range=! mapping-range=)

    ;; Linear-update range< is pure in this portable implementation.
    (define mapping-range<! mapping-range<)

    ;; Linear-update range> is pure in this portable implementation.
    (define mapping-range>! mapping-range>)

    ;; Linear-update range<= is pure in this portable implementation.
    (define mapping-range<=! mapping-range<=)

    ;; Linear-update range>= is pure in this portable implementation.
    (define mapping-range>=! mapping-range>=)

    (define (mapping-split mapping obj)
      "Split MAPPING around OBJ and return five range mappings."
      #((parameters
         (mapping (type mapping)
          (description "Ordered mapping to split."))
         (obj (type any)
          (description "Boundary key.")))
        (returns (type any)
         (description
          "Five values: <, <=, =, >=, and > range mappings."))
        (effects allocation error procedure-call))
      (assume (mapping? mapping))
      (let ((comparator (mapping-key-comparator mapping)))
        (receive (tree< tree<= tree= tree>= tree>)
            (tree-split comparator (mapping-tree mapping) obj)
          (values (%make-mapping comparator tree<)
                  (%make-mapping comparator tree<=)
                  (%make-mapping comparator tree=)
                  (%make-mapping comparator tree>=)
                  (%make-mapping comparator tree>)))))

    (define (mapping-catenate comparator mapping1 pivot-key pivot-value mapping2)
      "Return MAPPING1, pivot association, and MAPPING2 as one mapping."
      #((parameters
         (comparator (type comparator)
          (description "Comparator controlling the result keys."))
         (mapping1 (type mapping)
          (description "Ordered mapping whose keys precede PIVOT-KEY."))
         (pivot-key (type any)
          (description "Key joining the two mappings."))
         (pivot-value (type any)
          (description "Value for PIVOT-KEY."))
         (mapping2 (type mapping)
          (description "Ordered mapping whose keys follow PIVOT-KEY.")))
        (returns (type mapping)
         (description "Catenated ordered mapping."))
        (effects allocation error))
      (assume (comparator? comparator))
      (assume (mapping? mapping1))
      (assume (mapping? mapping2))
      (%make-mapping comparator
                     (tree-catenate (mapping-tree mapping1)
                                    pivot-key
                                    pivot-value
                                    (mapping-tree mapping2))))

    ;; Linear-update catenate is pure in this portable implementation.
    (define mapping-catenate! mapping-catenate)

    (define (mapping-map/monotone proc comparator mapping)
      "Return a mapping from monotone PROC over MAPPING."
      #((parameters
         (proc (type procedure)
          (description "Procedure accepting key and value and returning two values."))
         (comparator (type comparator)
          (description "Comparator controlling the result keys."))
         (mapping (type mapping)
          (description "Ordered mapping to transform.")))
        (returns (type mapping)
         (description "Transformed ordered mapping."))
        (effects allocation error procedure-call))
      (assume (procedure? proc))
      (assume (comparator? comparator))
      (assume (mapping? mapping))
      (%make-mapping comparator (tree-map proc (mapping-tree mapping))))

    ;; Linear-update map/monotone is pure in this portable implementation.
    (define mapping-map/monotone! mapping-map/monotone)

    (define (mapping-fold/reverse proc acc mapping)
      "Fold PROC over MAPPING from greatest key to least key."
      #((parameters
         (proc (type procedure)
          (description "Procedure called as (proc key value accumulator)."))
         (acc (type any)
          (description "Initial accumulator."))
         (mapping (type mapping)
          (description "Ordered mapping to fold.")))
        (returns (type any)
         (description "Final accumulator."))
        (effects error procedure-call))
      (assume (procedure? proc))
      (assume (mapping? mapping))
      (tree-fold/reverse proc acc (mapping-tree mapping)))

    (define (mapping-equality comparator)
      "Return equality for mappings whose values use COMPARATOR."
      (assume (comparator? comparator))
      (lambda (mapping1 mapping2)
        (mapping=? comparator mapping1 mapping2)))

    (define (mapping-ordering comparator)
      "Return ordering for mappings whose values use COMPARATOR."
      (assume (comparator? comparator))
      (let ((value-equality (comparator-equality-predicate comparator))
            (value-ordering (comparator-ordering-predicate comparator)))
        (lambda (mapping1 mapping2)
          (let* ((key-comparator (mapping-key-comparator mapping1))
                 (equality (comparator-equality-predicate key-comparator))
                 (ordering (comparator-ordering-predicate key-comparator))
                 (gen1 (tree-generator (mapping-tree mapping1)))
                 (gen2 (tree-generator (mapping-tree mapping2))))
            (let loop ()
              (let ((item1 (gen1)) (item2 (gen2)))
                (cond
                 ((eof-object? item1)
                  (not (eof-object? item2)))
                 ((eof-object? item2)
                  #f)
                 (else
                  (let ((key1 (car item1))
                        (value1 (cadr item1))
                        (key2 (car item2))
                        (value2 (cadr item2)))
                    (cond
                     ((equality key1 key2)
                      (if (value-equality value1 value2)
                          (loop)
                          (value-ordering value1 value2)))
                     (else
                      (ordering key1 key2))))))))))))

    (define (make-mapping-comparator comparator)
      "Return a comparator for mappings whose values use COMPARATOR."
      #((parameters
         (comparator (type comparator)
          (description "Comparator used for mapping values.")))
        (returns (type comparator)
         (description "Comparator accepting ordered mappings."))
        (effects allocation error))
      (make-comparator mapping?
                       (mapping-equality comparator)
                       (mapping-ordering comparator)
                       #f))

    ;; Default comparator support for ordered mappings.
    (define mapping-comparator
      (make-mapping-comparator (make-default-comparator)))

    (comparator-register-default! mapping-comparator)))
