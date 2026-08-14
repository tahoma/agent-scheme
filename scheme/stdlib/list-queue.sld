;;; SRFI 117 list-queue support for stdlib.
;; SPDX-License-Identifier: BSD-3-Clause
;; SPDX-FileCopyrightText: 2017 Alex Shinn
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Adapted from the official SRFI 117 sample implementation at
;;; https://github.com/scheme-requests-for-implementation/srfi-117.
;;; List queues retain the standard's exposed list representation. They do not
;;; reuse Consent's private ring-buffer worklist because callers can observe and
;;; mutate the first and last pairs through this public API.

(define-library (stdlib list-queue)
  (export
   make-list-queue
   list-queue
   list-queue-copy
   list-queue-unfold
   list-queue-unfold-right
   list-queue?
   list-queue-empty?
   list-queue-front
   list-queue-back
   list-queue-list
   list-queue-first-last
   list-queue-add-front!
   list-queue-add-back!
   list-queue-remove-front!
   list-queue-remove-back!
   list-queue-remove-all!
   list-queue-set-list!
   list-queue-append
   list-queue-append!
   list-queue-concatenate
   list-queue-map
   list-queue-map!
   list-queue-for-each)
  (import (scheme base)
          (scheme case-lambda))
  (begin
    ;; A queue is empty at both ends or points at the first and final pairs.
    (define-record-type <list-queue>
      (make-list-queue-record first last)
      list-queue-record?
      (first list-queue-first-pair set-list-queue-first-pair!)
      (last list-queue-last-pair set-list-queue-last-pair!))

    (define (unspecified)
      "Return one unspecified value portably."
      (if #f #f))

    (define (check-list-queue operation queue)
      "Validate QUEUE as a list queue for OPERATION."
      (if (not (list-queue-record? queue))
          (error (string-append operation ": expected list queue") queue))
      queue)

    (define (proper-list-last-pair operation items)
      "Return ITEMS' final pair, or signal an improper-list error."
      (let loop ((rest items))
        (cond
         ((null? rest) '())
         ((not (pair? rest))
          (error (string-append operation ": expected proper list") items))
         ((null? (cdr rest)) rest)
         (else (loop (cdr rest))))))

    (define (check-explicit-ends operation first last)
      "Check the constant-time FIRST and LAST pair boundary for OPERATION."
      (if (not
           (or (and (null? first) (null? last))
               (and (pair? first)
                    (pair? last))))
          (error
           (string-append operation ": inconsistent first and last pairs")
           first
           last)))

    (define (make-list-queue items . maybe-last)
      "Return a list queue sharing ITEMS and optionally its final pair."
      #((parameters
         (items (type list)
          (description "List whose pairs back the new queue."))
         (maybe-last (type list)
          (description "Zero or one explicit final pair from ITEMS.")))
        (returns (type list-queue)
         (description "A fresh queue sharing ITEMS' pair storage."))
        (effects allocation))
      (apply
       (case-lambda
        (()
         (make-list-queue-record
          items
          (proper-list-last-pair "make-list-queue" items)))
        ((last)
         (check-explicit-ends "make-list-queue" items last)
         (make-list-queue-record items last)))
       maybe-last))

    (define (list-queue . elements)
      "Return a fresh list queue containing ELEMENTS in argument order."
      #((parameters
         (elements (type list)
          (description "Elements to store from front to back.")))
        (returns (type list-queue)
         (description "A fresh queue containing ELEMENTS."))
        (effects allocation))
      (make-list-queue elements))

    (define (list-queue-copy queue)
      "Return a fresh list queue containing QUEUE's elements."
      #((parameters
         (queue (type list-queue)
          (description "Queue whose element sequence is copied.")))
        (returns (type list-queue)
         (description "An independent shallow copy of QUEUE."))
        (effects allocation))
      (check-list-queue "list-queue-copy" queue)
      (make-list-queue (list-copy (list-queue-first-pair queue))))

    (define (collect-unfold-values stop? mapper successor seed)
      "Return mapped unfold values in reverse seed order."
      (let loop ((current seed) (values '()))
        (if (stop? current)
            values
            (let ((mapped (mapper current)))
              (let ((next (successor current)))
                (loop next (cons mapped values)))))))

    (define (list-queue-unfold stop? mapper successor seed . maybe-queue)
      "Prepend mapped seeds in unfold order to an optional queue."
      #((parameters
         (stop? (type procedure)
          (description "Predicate that ends unfolding for a seed."))
         (mapper (type procedure)
          (description "Procedure mapping each active seed to an element."))
         (successor (type procedure)
          (description "Procedure advancing one seed to the next."))
         (seed (type any)
          (description "Initial unfold seed."))
         (maybe-queue (type list)
          (description "Zero or one queue to receive prepended elements.")))
        (returns (type list-queue)
         (description "The supplied or fresh queue after unfolding."))
        (effects allocation callback state-write))
      (apply
       (case-lambda
        (()
         (list-queue-unfold stop? mapper successor seed (list-queue)))
        ((queue)
         (check-list-queue "list-queue-unfold" queue)
         (for-each
          (lambda (value) (list-queue-add-front! queue value))
          (collect-unfold-values stop? mapper successor seed))
         queue))
       maybe-queue))

    (define (list-queue-unfold-right
             stop? mapper successor seed . maybe-queue)
      "Append mapped seeds in right-unfold order to an optional queue."
      #((parameters
         (stop? (type procedure)
          (description "Predicate that ends unfolding for a seed."))
         (mapper (type procedure)
          (description "Procedure mapping each active seed to an element."))
         (successor (type procedure)
          (description "Procedure advancing one seed to the next."))
         (seed (type any)
          (description "Initial unfold seed."))
         (maybe-queue (type list)
          (description "Zero or one queue to receive appended elements.")))
        (returns (type list-queue)
         (description "The supplied or fresh queue after unfolding."))
        (effects allocation callback state-write))
      (apply
       (case-lambda
        (()
         (list-queue-unfold-right
          stop? mapper successor seed (list-queue)))
        ((queue)
         (check-list-queue "list-queue-unfold-right" queue)
         (for-each
          (lambda (value) (list-queue-add-back! queue value))
          (collect-unfold-values stop? mapper successor seed))
         queue))
       maybe-queue))

    (define (list-queue? value)
      "Return whether VALUE is a list queue."
      #((parameters
         (value (type any)
          (description "Candidate object to inspect.")))
        (returns (type boolean)
         (description "Whether VALUE is a list queue."))
        (effects pure))
      (list-queue-record? value))

    (define (list-queue-empty? queue)
      "Return whether QUEUE contains no elements."
      #((parameters
         (queue (type list-queue)
          (description "Queue to test for emptiness.")))
        (returns (type boolean)
         (description "Whether QUEUE has no elements."))
        (effects pure))
      (check-list-queue "list-queue-empty?" queue)
      (null? (list-queue-first-pair queue)))

    (define (list-queue-front queue)
      "Return QUEUE's front element."
      #((parameters
         (queue (type list-queue)
          (description "Nonempty queue whose front is returned.")))
        (returns (type any)
         (description "QUEUE's first element."))
        (effects pure))
      (check-list-queue "list-queue-front" queue)
      (if (list-queue-empty? queue)
          (error "list-queue-front: empty list queue"))
      (car (list-queue-first-pair queue)))

    (define (list-queue-back queue)
      "Return QUEUE's back element."
      #((parameters
         (queue (type list-queue)
          (description "Nonempty queue whose back is returned.")))
        (returns (type any)
         (description "QUEUE's final element."))
        (effects pure))
      (check-list-queue "list-queue-back" queue)
      (if (list-queue-empty? queue)
          (error "list-queue-back: empty list queue"))
      (car (list-queue-last-pair queue)))

    (define (list-queue-list queue)
      "Return QUEUE's shared backing list."
      #((parameters
         (queue (type list-queue)
          (description "Queue whose backing list is returned.")))
        (returns (type list)
         (description "The list sharing QUEUE's element pairs."))
        (effects pure))
      (check-list-queue "list-queue-list" queue)
      (list-queue-first-pair queue))

    (define (list-queue-first-last queue)
      "Return QUEUE's shared first and final pairs as two values."
      #((parameters
         (queue (type list-queue)
          (description "Queue whose endpoint pairs are returned.")))
        (returns (type (values list list))
         (description "QUEUE's first and final pairs, or two empty lists."))
        (effects pure))
      (check-list-queue "list-queue-first-last" queue)
      (values
       (list-queue-first-pair queue)
       (list-queue-last-pair queue)))

    (define (list-queue-add-front! queue element)
      "Add ELEMENT to QUEUE's front and return an unspecified value."
      #((parameters
         (queue (type list-queue)
          (description "Queue to mutate."))
         (element (type any)
          (description "Element to add at the front.")))
        (returns (type unspecified)
         (description "An unspecified value."))
        (effects allocation state-write))
      (check-list-queue "list-queue-add-front!" queue)
      (let ((new-first
             (cons element (list-queue-first-pair queue))))
        (if (list-queue-empty? queue)
            (set-list-queue-last-pair! queue new-first))
        (set-list-queue-first-pair! queue new-first)
        (unspecified)))

    (define (list-queue-add-back! queue element)
      "Add ELEMENT to QUEUE's back and return an unspecified value."
      #((parameters
         (queue (type list-queue)
          (description "Queue to mutate."))
         (element (type any)
          (description "Element to add at the back.")))
        (returns (type unspecified)
         (description "An unspecified value."))
        (effects allocation state-write))
      (check-list-queue "list-queue-add-back!" queue)
      (let ((new-last (list element)))
        (if (list-queue-empty? queue)
            (set-list-queue-first-pair! queue new-last)
            (set-cdr! (list-queue-last-pair queue) new-last))
        (set-list-queue-last-pair! queue new-last)
        (unspecified)))

    (define (list-queue-remove-front! queue)
      "Remove and return QUEUE's front element."
      #((parameters
         (queue (type list-queue)
          (description "Nonempty queue to mutate.")))
        (returns (type any)
         (description "The removed front element."))
        (effects state-write))
      (check-list-queue "list-queue-remove-front!" queue)
      (if (list-queue-empty? queue)
          (error "list-queue-remove-front!: empty list queue"))
      (let* ((old-first (list-queue-first-pair queue))
             (element (car old-first))
             (new-first (cdr old-first)))
        (if (null? new-first)
            (set-list-queue-last-pair! queue '()))
        (set-list-queue-first-pair! queue new-first)
        element))

    (define (penultimate-pair items)
      "Return ITEMS' penultimate pair, or the empty list for one pair."
      (let loop ((rest items))
        (cond
         ((null? (cdr rest)) '())
         ((null? (cddr rest)) rest)
         (else (loop (cdr rest))))))

    (define (list-queue-remove-back! queue)
      "Remove and return QUEUE's back element."
      #((parameters
         (queue (type list-queue)
          (description "Nonempty queue to mutate.")))
        (returns (type any)
         (description "The removed back element."))
        (effects state-write))
      (check-list-queue "list-queue-remove-back!" queue)
      (if (list-queue-empty? queue)
          (error "list-queue-remove-back!: empty list queue"))
      (let* ((old-last (list-queue-last-pair queue))
             (element (car old-last))
             (new-last
              (penultimate-pair (list-queue-first-pair queue))))
        (if (null? new-last)
            (set-list-queue-first-pair! queue '())
            (set-cdr! new-last '()))
        (set-list-queue-last-pair! queue new-last)
        element))

    (define (list-queue-remove-all! queue)
      "Remove all elements from QUEUE and return its former backing list."
      #((parameters
         (queue (type list-queue)
          (description "Queue to clear.")))
        (returns (type list)
         (description "QUEUE's former shared backing list."))
        (effects state-write))
      (check-list-queue "list-queue-remove-all!" queue)
      (let ((result (list-queue-first-pair queue)))
        (set-list-queue-first-pair! queue '())
        (set-list-queue-last-pair! queue '())
        result))

    (define (list-queue-set-list! queue items . maybe-last)
      "Replace QUEUE's shared ITEMS and optional final pair."
      #((parameters
         (queue (type list-queue)
          (description "Queue whose backing list is replaced."))
         (items (type list)
          (description "New shared backing list."))
         (maybe-last (type list)
          (description "Zero or one explicit final pair from ITEMS.")))
        (returns (type unspecified)
         (description "An unspecified value."))
        (effects state-write))
      (check-list-queue "list-queue-set-list!" queue)
      (apply
       (case-lambda
        (()
         (let ((last
                (proper-list-last-pair
                 "list-queue-set-list!"
                 items)))
           (set-list-queue-first-pair! queue items)
           (set-list-queue-last-pair! queue last)))
        ((last)
         (check-explicit-ends "list-queue-set-list!" items last)
         (set-list-queue-first-pair! queue items)
         (set-list-queue-last-pair! queue last)))
       maybe-last)
      (unspecified))

    (define (list-queue-append . queues)
      "Return a fresh queue containing copies of QUEUES' elements."
      #((parameters
         (queues (type list)
          (description "Queues to append in argument order.")))
        (returns (type list-queue)
         (description "An independent concatenation of QUEUES."))
        (effects allocation))
      (list-queue-concatenate queues))

    (define (join-list-queues! result queue)
      "Destructively join QUEUE after RESULT and update both endpoints."
      (cond
       ((list-queue-empty? queue) (unspecified))
       ((list-queue-empty? result)
        (set-list-queue-first-pair!
         result
         (list-queue-first-pair queue))
        (set-list-queue-last-pair!
         result
         (list-queue-last-pair queue)))
       (else
        (set-cdr!
         (list-queue-last-pair result)
         (list-queue-first-pair queue))
        (set-list-queue-last-pair!
         result
         (list-queue-last-pair queue)))))

    (define (list-queue-append! . queues)
      "Destructively append QUEUES and return the first queue."
      #((parameters
         (queues (type list)
          (description "Queues whose storage may be joined destructively.")))
        (returns (type list-queue)
         (description "The first queue, or a fresh empty queue."))
        (effects allocation state-write))
      (if (null? queues)
          (list-queue)
          (let ((result (check-list-queue
                         "list-queue-append!"
                         (car queues))))
            (for-each
             (lambda (queue)
               (check-list-queue "list-queue-append!" queue))
             (cdr queues))
            (for-each
             (lambda (queue) (join-list-queues! result queue))
             (cdr queues))
            result)))

    (define (list-queue-concatenate queues)
      "Return a fresh queue containing copies of QUEUES' elements."
      #((parameters
         (queues (type list)
          (description "List of queues to concatenate in order.")))
        (returns (type list-queue)
         (description "An independent concatenation of QUEUES."))
        (effects allocation))
      (let ((result (list-queue)))
        (for-each
         (lambda (queue)
           (check-list-queue "list-queue-concatenate" queue)
           (for-each
            (lambda (element)
              (list-queue-add-back! result element))
            (list-queue-first-pair queue)))
         queues)
        result))

    (define (list-queue-map proc queue)
      "Return a fresh queue of PROC applied to QUEUE's elements."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping each queue element."))
         (queue (type list-queue)
          (description "Queue whose elements are mapped.")))
        (returns (type list-queue)
         (description "A fresh queue containing mapped elements."))
        (effects allocation callback))
      (check-list-queue "list-queue-map" queue)
      (make-list-queue
       (map proc (list-queue-first-pair queue))))

    (define (map-list-queue-pairs! proc items)
      "Replace each pair car in ITEMS with PROC's result."
      (let loop ((rest items))
        (if (pair? rest)
            (begin
              (set-car! rest (proc (car rest)))
              (loop (cdr rest))))))

    (define (list-queue-map! proc queue)
      "Replace QUEUE's elements with PROC results in front-to-back order."
      #((parameters
         (proc (type procedure)
          (description "Procedure mapping each queue element."))
         (queue (type list-queue)
          (description "Queue to mutate in place.")))
        (returns (type unspecified)
         (description "An unspecified value."))
        (effects callback state-write))
      (check-list-queue "list-queue-map!" queue)
      (map-list-queue-pairs! proc (list-queue-first-pair queue))
      (unspecified))

    (define (list-queue-for-each proc queue)
      "Apply PROC to QUEUE's elements in front-to-back order."
      #((parameters
         (proc (type procedure)
          (description "Procedure called for each queue element."))
         (queue (type list-queue)
          (description "Queue traversed from front to back.")))
        (returns (type unspecified)
         (description "An unspecified value."))
        (effects callback))
      (check-list-queue "list-queue-for-each" queue)
      (for-each proc (list-queue-first-pair queue))
      (unspecified))))
