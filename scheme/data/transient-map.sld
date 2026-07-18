;;; Public mutable overlay for persistent maps.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (data transient-map)
  (export make-transient-map
          transient-map?
          transient-map-contains?
          transient-map-ref
          transient-map-ref/default
          transient-map-set!
          transient-map-delete!
          transient-map-pending-count
          transient-map-persistent!
          transient-map-reset!)
  (import (scheme base))
  (begin
    ;; Initial sparse overlay capacity before growth.
    (define transient-map-initial-capacity 127)

    ;; One staged or cached overlay association.
    (define-record-type <transient-map-entry>
      (make-transient-map-entry key value kind)
      transient-map-entry?
      (key transient-map-entry-key)
      (value transient-map-entry-value)
      (kind transient-map-entry-kind))

    ;; Mutable overlay layered over an arbitrary persistent base.
    (define-record-type <transient-map>
      (make-transient-map-record
       base hash equivalent key-copy base-ref base-set base-delete
       slots count pending-count)
      transient-map?
      (base transient-map-base set-transient-map-base!)
      (hash transient-map-hash)
      (equivalent transient-map-equivalent)
      (key-copy transient-map-key-copy)
      (base-ref transient-map-base-ref)
      (base-set transient-map-base-set)
      (base-delete transient-map-base-delete)
      (slots transient-map-slots set-transient-map-slots!)
      (count transient-map-count set-transient-map-count!)
      (pending-count transient-map-pending-count
                     set-transient-map-pending-count!))

    (define (make-transient-map
             base hash equivalent base-ref base-set base-delete
             . maybe-key-copy)
      "Return a mutable overlay initially backed by persistent BASE."
      #((parameters
         (base (type any) (description "Persistent base map."))
         (hash (type procedure)
          (description "Procedure returning an exact integer key hash."))
         (equivalent (type procedure)
          (description "Procedure comparing keys for equivalence."))
         (base-ref (type procedure)
          (description "Persistent-base lookup adapter."))
         (base-set (type procedure)
          (description "Persistent-base functional set adapter."))
         (base-delete (type procedure)
          (description "Persistent-base functional delete adapter."))
         (maybe-key-copy (type list)
          (description "Optional procedure stabilizing retained keys.")))
        (returns (type transient-map)
         (description "Fresh mutable overlay."))
        (effects allocation error))
      (for-each
       (lambda (name procedure)
         (if (not (procedure? procedure))
             (error (string-append
                     "make-transient-map: expected procedure for " name)
                    procedure)))
       '("hash" "equivalent" "base-ref" "base-set" "base-delete")
       (list hash equivalent base-ref base-set base-delete))
      (if (> (length maybe-key-copy) 1)
          (error "make-transient-map: too many key-copy procedures"))
      (let ((key-copy (if (null? maybe-key-copy)
                          (lambda (key) key)
                          (car maybe-key-copy))))
        (if (not (procedure? key-copy))
            (error "make-transient-map: expected key-copy procedure"
                   key-copy))
        (make-transient-map-record
         base hash equivalent key-copy base-ref base-set base-delete
         (make-vector transient-map-initial-capacity #f)
         0
         0)))

    (define (transient-map-start-index transient key slots)
      "Return KEY's initial probe index in SLOTS."
      (let ((hash ((transient-map-hash transient) key)))
        (if (not (and (integer? hash) (exact? hash)))
            (error "transient map hash must return an exact integer" hash))
        (modulo hash (vector-length slots))))

    (define (transient-map-find transient key slots)
      "Return KEY's slot index and entry, or insertion index and #f."
      (let ((capacity (vector-length slots))
            (start (transient-map-start-index transient key slots))
            (equivalent (transient-map-equivalent transient)))
        (let loop ((offset 0))
          (if (= offset capacity)
              (error "transient map overlay has no empty slot"))
          (let* ((index (modulo (+ start offset) capacity))
                 (entry (vector-ref slots index)))
            (if (or (not entry)
                    (equivalent key (transient-map-entry-key entry)))
                (values index entry)
                (loop (+ offset 1)))))))

    (define (transient-map-insert-entry! transient entry)
      "Insert ENTRY into TRANSIENT's current slots without resizing."
      (let ((slots (transient-map-slots transient)))
        (call-with-values
            (lambda ()
              (transient-map-find
               transient (transient-map-entry-key entry) slots))
          (lambda (index previous)
            (vector-set! slots index entry)
            (if (not previous)
                (set-transient-map-count!
                 transient
                 (+ (transient-map-count transient) 1)))))))

    (define (transient-map-resize! transient)
      "Grow and rehash TRANSIENT's overlay slots."
      (let* ((old-slots (transient-map-slots transient))
             (new-slots
              (make-vector (+ (* 2 (vector-length old-slots)) 1) #f)))
        (set-transient-map-slots! transient new-slots)
        (set-transient-map-count! transient 0)
        (let loop ((index 0))
          (if (< index (vector-length old-slots))
              (begin
                (let ((entry (vector-ref old-slots index)))
                  (if entry (transient-map-insert-entry! transient entry)))
                (loop (+ index 1)))))))

    (define (transient-map-ensure-capacity! transient)
      "Grow TRANSIENT before its open-addressed overlay becomes crowded."
      (let ((slots (transient-map-slots transient)))
        (if (>= (* (+ (transient-map-count transient) 1) 3)
                (* (vector-length slots) 2))
            (transient-map-resize! transient))))

    (define (transient-map-store! transient key value kind)
      "Store KEY, VALUE, and KIND in TRANSIENT's overlay."
      (transient-map-ensure-capacity! transient)
      (let* ((stable-key ((transient-map-key-copy transient) key))
             (entry (make-transient-map-entry stable-key value kind))
             (slots (transient-map-slots transient)))
        (call-with-values
            (lambda () (transient-map-find transient stable-key slots))
          (lambda (index previous)
            (let ((previous-kind
                   (and previous (transient-map-entry-kind previous))))
              (if (and (eq? kind 'cached)
                       (or (eq? previous-kind 'set)
                           (eq? previous-kind 'deleted)))
                  transient
                  (begin
                    (vector-set! slots index entry)
                    (if (not previous)
                        (set-transient-map-count!
                         transient
                         (+ (transient-map-count transient) 1)))
                    (if (or (and (not previous)
                                 (not (eq? kind 'cached)))
                            (and (eq? previous-kind 'cached)
                                 (not (eq? kind 'cached))))
                        (set-transient-map-pending-count!
                         transient
                         (+ (transient-map-pending-count transient) 1)))
                    transient)))))))

    (define (transient-map-ref transient key . rest)
      "Return KEY's value from TRANSIENT or its persistent base."
      #((parameters
         (transient (type transient-map)
          (description "Overlay to search."))
         (key (type any) (description "Key to search for."))
         (rest (type list)
          (description "Optional failure and success procedures.")))
        (returns (type any) (description "Associated value."))
        (effects allocation state-write error procedure-call))
      (if (not (transient-map? transient))
          (error "transient-map-ref: expected transient map" transient))
      (if (> (length rest) 2)
          (error "transient-map-ref: too many procedures"))
      (let ((failure (if (null? rest)
                         (lambda ()
                           (error "transient map key is not present" key))
                         (car rest)))
            (success (if (or (null? rest) (null? (cdr rest)))
                         (lambda (value) value)
                         (cadr rest))))
        (call-with-values
            (lambda ()
              (transient-map-find
               transient key (transient-map-slots transient)))
          (lambda (index entry)
            (cond
             ((and entry (eq? (transient-map-entry-kind entry) 'deleted))
              (failure))
             (entry (success (transient-map-entry-value entry)))
             (else
              ((transient-map-base-ref transient)
               (transient-map-base transient)
               key
               failure
               (lambda (value)
                 (transient-map-store! transient key value 'cached)
                 (success value)))))))))

    (define (transient-map-ref/default transient key default)
      "Return KEY's value from TRANSIENT, or DEFAULT when absent."
      #((parameters
         (transient (type transient-map) (description "Overlay to search."))
         (key (type any) (description "Key to locate."))
         (default (type any) (description "Absent-key result.")))
        (returns (type any) (description "Stored value or DEFAULT."))
        (effects allocation state-write procedure-call error))
      (transient-map-ref transient key (lambda () default)))

    (define (transient-map-contains? transient key)
      "Return #t when TRANSIENT contains KEY."
      #((parameters
         (transient (type transient-map) (description "Overlay to search."))
         (key (type any) (description "Key to locate.")))
        (returns (type boolean) (description "Whether KEY is present."))
        (effects allocation state-write procedure-call error))
      (transient-map-ref transient key (lambda () #f) (lambda (value) #t)))

    (define (transient-map-set! transient key value)
      "Associate KEY with VALUE in TRANSIENT and return TRANSIENT."
      #((parameters
         (transient (type transient-map) (description "Overlay to mutate."))
         (key (type any) (description "Key to associate."))
         (value (type any) (description "Value to store.")))
        (returns (type transient-map) (description "Mutated TRANSIENT."))
        (effects allocation state-write procedure-call error))
      (if (not (transient-map? transient))
          (error "transient-map-set!: expected transient map" transient))
      (transient-map-store! transient key value 'set))

    (define (transient-map-delete! transient key)
      "Hide KEY in TRANSIENT and delete it at materialization."
      #((parameters
         (transient (type transient-map) (description "Overlay to mutate."))
         (key (type any) (description "Key to hide.")))
        (returns (type transient-map) (description "Mutated TRANSIENT."))
        (effects allocation state-write procedure-call error))
      (if (not (transient-map? transient))
          (error "transient-map-delete!: expected transient map" transient))
      (transient-map-store! transient key #f 'deleted))

    (define (transient-map-persistent! transient)
      "Materialize TRANSIENT's staged changes and return its persistent base."
      #((parameters
         (transient (type transient-map)
          (description "Overlay to materialize.")))
        (returns (type any) (description "Updated persistent base."))
        (effects allocation state-write procedure-call error))
      (if (not (transient-map? transient))
          (error "transient-map-persistent!: expected transient map"
                 transient))
      (let ((slots (transient-map-slots transient)))
        (let loop ((index 0) (base (transient-map-base transient)))
          (if (= index (vector-length slots))
              (begin
                (set-transient-map-base! transient base)
                (vector-fill! slots #f)
                (set-transient-map-count! transient 0)
                (set-transient-map-pending-count! transient 0)
                base)
              (let ((entry (vector-ref slots index)))
                (loop
                 (+ index 1)
                 (cond
                  ((not entry) base)
                  ((eq? (transient-map-entry-kind entry) 'set)
                   ((transient-map-base-set transient)
                    base
                    (transient-map-entry-key entry)
                    (transient-map-entry-value entry)))
                  ((eq? (transient-map-entry-kind entry) 'deleted)
                   ((transient-map-base-delete transient)
                    base
                    (transient-map-entry-key entry)))
                  (else base))))))))

    (define (transient-map-reset! transient base)
      "Replace TRANSIENT's persistent BASE and clear its overlay."
      #((parameters
         (transient (type transient-map) (description "Overlay to reset."))
         (base (type any) (description "Replacement persistent base.")))
        (returns (type transient-map) (description "Reset TRANSIENT."))
        (effects state-write error))
      (if (not (transient-map? transient))
          (error "transient-map-reset!: expected transient map" transient))
      (set-transient-map-base! transient base)
      (vector-fill! (transient-map-slots transient) #f)
      (set-transient-map-count! transient 0)
      (set-transient-map-pending-count! transient 0)
      transient)))
