;;; Canonical ordered memory-key kernel.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;
;;; `memory-prepare-index-key' is the nonmemoizing one-shot durability entry
;;; point; `call-with-memory-index-key-session' is the dynamic-extent bulk
;;; entry point that interns repeated root/scope descriptors.  Both return
;;; detached immutable-by-convention keys and reject private interpreted data.
;;;
;;; Hash-backed host identity and intrusive owned-object discovery feed fixed-
;;; rank partition refinement in O((V + E + C) log(V + E)), where C is copied
;;; and compared scalar content.  Owned pair/vector discovery is intrusive;
;;; immutable scalar wrappers and host nodes use the identity adapter so shared
;;; large payloads are copied once.  A host compound or nested identity scalar
;;; fails closed without a fast backend.  Bulk no-hash sessions keep only a
;;; fixed 64-entry identity alist before failing closed, so compatibility work
;;; cannot become quadratic.  A descriptor comparison is O(K), so an AVL
;;; operation is O(K log R) in the worst case and avoids K-token scans when
;;; canonical descriptor identity is shared.  Raw host numbers additionally
;;; inherit the adapter's T_number->string cost; owned canonical-number
;;; snapshots are linear in their stored representation.

(define-library (agent memory-key)
  (export memory-prepare-index-key
          call-with-memory-index-key-session
          memory-index-key-sealed-wrapper?
          memory-index-key-bounded-comparison?
          memory-index-key?
          memory-index-key<?
          memory-index-key=?
          memory-index-key-symbol-name)
  (import (scheme base)
        (only (consent character)
              consent-character?
              consent-character-code)
        (only (consent datum)
              consent-datum-object?
              consent-make-datum-object-map
              consent-datum-object-map-ref
              consent-datum-object-map-set!
              consent-datum-object-map-release!
              consent-datum-pair?
              consent-datum-car
              consent-datum-cdr
              consent-datum-string?
              consent-datum-string-length
              consent-datum-string-ref-host
              consent-datum-vector?
              consent-datum-vector-length
              consent-datum-vector-ref
              consent-datum-bytevector?
              consent-datum-bytevector-length
              consent-datum-bytevector-u8-ref)
        (only (consent dense-set)
              consent-make-dense-set
              consent-dense-set-clear!
              consent-dense-set-mark!
              consent-dense-set-member?
              consent-dense-set-release!
              consent-dense-set-unmark!)
        (only (consent identity-map)
              consent-identity-map-fast-backend?
              consent-make-identity-map
              consent-identity-map-ref
              consent-identity-map-set!)
        (only (consent reader)
              consent-number-representation-snapshot
              consent-outer-representation-kind)
        (only (consent growable-vector)
              consent-make-growable-vector
              consent-growable-vector-append!
              consent-growable-vector-ref
              consent-growable-vector-release!
              consent-growable-vector-set!
              consent-growable-vector-snapshot)
        (only (consent worklist)
              consent-make-worklist
              consent-worklist-empty?
              consent-worklist-pop-front!
              consent-worklist-push-back!
              consent-worklist-release!)
        (only (consent symbol)
              consent-symbol?
              consent-symbol-name)
        (only (data avl-tree)
              make-avl-tree
              avl-tree-ref
              avl-tree-set
              avl-tree-fold))
  (begin

;;;; Small mutable utilities used only while preparing an immutable key.

;; A single key preparation is already bounded by evaluator work budgets. This
;; exact ceiling additionally prevents an unbounded host-vector request when
;; the kernel runs directly on an R7RS bootstrap host.
(define memory-key-maximum-growable-capacity 536870911)

;; Generation stamps stay in the same bounded exact-integer profile as graph
;; storage.  Wraparound remains correct if an adversarial refinement reaches
;; the ceiling; ordinary keys do not approach it.
(define memory-key-maximum-dense-generation 536870911)

(define (make-memory-key-growable-vector)
  "Return bounded growable storage for one memory-key preparation."
  (consent-make-growable-vector
   16 memory-key-maximum-growable-capacity))

(define (make-memory-key-worklist maximum-capacity)
  "Return a bounded FIFO for at most MAXIMUM-CAPACITY graph states."
  (consent-make-worklist
   (min 16 maximum-capacity) maximum-capacity 'allow-growth))

(define (make-memory-key-dense-set capacity domain)
  "Return a pre-reserved one-color dense set for graph DOMAIN."
  (consent-make-dense-set
   capacity
   capacity
   memory-key-maximum-dense-generation
   1
   'pre-reserved
   domain))

;;;; Exact observable labels.

;; Labels are immutable-by-convention private vectors.  Pair/vector identity
;; never appears in a label.  Vector arity is represented by the fixed-rank
;; VECTOR-SLOT chain and VECTOR-END, not by an arbitrary transition alphabet.
;; Numeric ranks for exact observable term-graph labels.
(define label-null 0)
;; Boolean label rank.
(define label-boolean 1)
;; Number label rank.
(define label-number 2)
;; Local-character label rank.
(define label-local-character 3)
;; Outer-character label rank.
(define label-outer-character 4)
;; Direct-host-character label rank.
(define label-host-character 5)
;; Local-symbol label rank.
(define label-local-symbol 6)
;; Outer-symbol label rank.
(define label-outer-symbol 7)
;; Direct-host-symbol label rank.
(define label-host-symbol 8)
;; Local-string label rank.
(define label-local-string 9)
;; Outer-string label rank.
(define label-outer-string 10)
;; Direct-host-string label rank.
(define label-host-string 11)
;; Local-bytevector label rank.
(define label-local-bytevector 12)
;; Outer-bytevector label rank.
(define label-outer-bytevector 13)
;; Direct-host-bytevector label rank.
(define label-host-bytevector 14)
;; Local-pair label rank.
(define label-local-pair 15)
;; Outer-pair label rank.
(define label-outer-pair 16)
;; Direct-host-pair label rank.
(define label-host-pair 17)
;; Local-vector-root label rank.
(define label-local-vector-root 18)
;; Outer-vector-root label rank.
(define label-outer-vector-root 19)
;; Direct-host-vector-root label rank.
(define label-host-vector-root 20)
;; Lowered vector-slot label rank.
(define label-vector-slot 21)
;; Lowered vector-end label rank.
(define label-vector-end 22)

;; The overlay returns one of these exact objects and never allocates.  The
;; default direct-host implementation returns DIRECT-REPRESENTATION-MARKER.
;; Distinct representation markers supplied to the owner overlay.
(define outer-pair-marker (vector #f))
;; Outer-vector marker.
(define outer-vector-marker (vector #f))
;; Outer-string marker.
(define outer-string-marker (vector #f))
;; Outer-bytevector marker.
(define outer-bytevector-marker (vector #f))
;; Outer-character marker.
(define outer-character-marker (vector #f))
;; Outer-symbol marker.
(define outer-symbol-marker (vector #f))
;; Outer-number marker.
(define outer-number-marker (vector #f))
;; Private duplicate-owner marker.
(define private-representation-marker (vector #f))
;; Direct-host representation marker.
(define direct-representation-marker (vector #f))
;; Ordered marker vector passed to the overlay primitive.
(define outer-representation-markers
  (vector outer-pair-marker
          outer-vector-marker
          outer-string-marker
          outer-bytevector-marker
          outer-character-marker
          outer-symbol-marker
          outer-number-marker
          private-representation-marker
          direct-representation-marker))

(define (outer-representation-kind value)
  "Return VALUE's owner-domain representation marker."
  (consent-outer-representation-kind
   value outer-representation-markers))

(define (bytevector->private-vector value)
  "Copy host bytevector VALUE into a private integer vector."
  (let* ((length (bytevector-length value))
         (copy (make-vector length 0)))
    (let loop ((index 0))
      (if (< index length)
          (begin
            (vector-set! copy index (bytevector-u8-ref value index))
            (loop (+ index 1)))))
    copy))

(define (owned-string->private-string value)
  "Copy owned string VALUE into a private host string."
  (let* ((length (consent-datum-string-length value))
         (copy (make-string length #\space)))
    (let loop ((index 0))
      (if (< index length)
          (begin
            (string-set!
             copy index
             (consent-datum-string-ref-host value index))
            (loop (+ index 1)))))
    copy))

(define (owned-bytevector->private-vector value)
  "Copy owned bytevector VALUE into a private integer vector."
  (let* ((length (consent-datum-bytevector-length value))
         (copy (make-vector length 0)))
    (let loop ((index 0))
      (if (< index length)
          (begin
            (vector-set!
             copy index (consent-datum-bytevector-u8-ref value index))
            (loop (+ index 1)))))
    copy))

(define (memory-pair? value)
  "Return #t when VALUE is an owned or host pair."
  (or (consent-datum-pair? value) (pair? value)))

(define (memory-pair-car value)
  "Return the car of owned or host pair VALUE."
  (if (eq? (outer-representation-kind value) outer-pair-marker)
      (car value)
      (if (consent-datum-pair? value)
          (consent-datum-car value)
          (car value))))

(define (memory-pair-cdr value)
  "Return the cdr of owned or host pair VALUE."
  (if (eq? (outer-representation-kind value) outer-pair-marker)
      (cdr value)
      (if (consent-datum-pair? value)
          (consent-datum-cdr value)
          (cdr value))))

(define (memory-vector? value)
  "Return #t when VALUE is an owned or host vector."
  (or (consent-datum-vector? value) (vector? value)))

(define (memory-vector-length value)
  "Return the length of owned or host vector VALUE."
  (if (eq? (outer-representation-kind value) outer-vector-marker)
      (vector-length value)
      (if (consent-datum-vector? value)
          (consent-datum-vector-length value)
          (vector-length value))))

(define (memory-vector-ref value index)
  "Return owned or host vector VALUE's element at INDEX."
  (if (eq? (outer-representation-kind value) outer-vector-marker)
      (vector-ref value index)
      (if (consent-datum-vector? value)
          (consent-datum-vector-ref value index)
          (vector-ref value index))))

;; Numeric representation ranks distinguish canonical and host atoms.
(define number-representation-owned 0)
;; Direct-host numeric representation rank.
(define number-representation-host 1)

;; Complete ordered-key kinds.  Distinct outer/direct fast kinds preserve the
;; same ownership distinction as the general quotient without paying the
;; quotient cost on ordinary public literals.
;; Detached memory-key representation ranks.
(define memory-key-outer-symbol-kind 0)
;; Direct-host symbol key rank.
(define memory-key-direct-symbol-kind 1)
;; Shared empty-list key rank.
(define memory-key-common-list-kind 2)
;; Outer fast-list key rank.
(define memory-key-outer-list-kind 3)
;; Direct-host fast-list key rank.
(define memory-key-direct-list-kind 4)
;; Outer string key rank.
(define memory-key-outer-string-kind 5)
;; Direct-host string key rank.
(define memory-key-direct-string-kind 6)
;; General canonical quotient key rank.
(define memory-key-general-kind 7)
;; Fast-list symbol token rank.
(define memory-list-symbol-part 0)
;; Fast-list integer token rank.
(define memory-list-integer-part 1)

;; Fast lists cover the small identifier tuples used by ordinary memory APIs.
;; Larger spines or scalar payloads route to identity-aware graph normalization
;; so this convenience path never duplicates unbounded content work.
;; Maximum number of tokens admitted by the fast-list path.
(define memory-fast-list-maximum-parts 16)
;; Maximum characters in one fast-list token.
(define memory-fast-list-maximum-token-size 128)
;; Maximum aggregate characters in one fast-list payload.
(define memory-fast-list-maximum-content-size 512)

(define (owned-number-descriptor snapshot)
  "Return an owned-number descriptor containing SNAPSHOT."
  (vector number-representation-owned
          snapshot))

(define (validated-host-number-text value radix)
  "Return fresh radix text when it round-trips under host `eqv?'."
  (guard (condition
          (else #f))
    (let* ((text (number->string value radix))
           (round-trip (string->number text radix)))
      (and round-trip
           (eqv? value round-trip)
           (string-copy text)))))

(define (host-number-descriptor value)
  "Return a detached exact descriptor for raw host number VALUE."
  (if (not (= value value))
      (error "memory key rejects a raw host NaN" value))
  (let* ((exactness (if (exact? value) 0 1))
         (radix-and-text
          (if (exact? value)
              (let ((hexadecimal
                     (validated-host-number-text value 16)))
                (if hexadecimal
                    (cons 16 hexadecimal)
                    (let ((decimal
                           (validated-host-number-text value 10)))
                      (and decimal (cons 10 decimal)))))
              (let ((decimal (validated-host-number-text value 10)))
                (and decimal (cons 10 decimal))))))
    (if (not radix-and-text)
        (error "memory key cannot snapshot raw host number" value))
    (vector number-representation-host
            exactness
            (car radix-and-text)
            (cdr radix-and-text))))

(define (proper-base-list? value)
  "Return #t when VALUE is an acyclic proper base-representation list."
  (let loop ((slow value) (fast value))
    (cond
     ((null? fast) #t)
     ((not (pair? fast)) #f)
     ((null? (cdr fast)) #t)
     ((not (pair? (cdr fast))) #f)
     (else
      (let ((next-slow (cdr slow))
            (next-fast (cddr fast)))
        (and (not (eq? next-slow next-fast))
             (loop next-slow next-fast)))))))

(define (fast-list-token-within-bounds? count content-size token)
  "Return #t when TOKEN fits the fast-list payload envelope."
  (let ((token-size (string-length token)))
    (and (< count memory-fast-list-maximum-parts)
         (<= token-size memory-fast-list-maximum-token-size)
         (<= (+ content-size token-size)
             memory-fast-list-maximum-content-size))))

(define (fast-list-payload key representation)
  "Return a detached typed payload for a homogeneous fast list, or #f."
  (if (not (proper-base-list? key))
      #f
      (let loop ((parts key)
                 (reversed '())
                 (count 0)
                 (content-size 0))
        (cond
         ((null? parts) (list->vector (reverse reversed)))
         ((symbol? (car parts))
          (let* ((element-representation
                  (outer-representation-kind (car parts)))
                 (name (symbol->string (car parts))))
            (if (and
                 (or
                  (and (eq? representation outer-pair-marker)
                       (eq? element-representation outer-symbol-marker))
                  (and (eq? representation direct-representation-marker)
                       (eq? element-representation
                            direct-representation-marker)))
                 (fast-list-token-within-bounds?
                  count content-size name))
                (loop (cdr parts)
                      (cons (string-copy name)
                            (cons memory-list-symbol-part reversed))
                      (+ count 1)
                      (+ content-size (string-length name)))
                #f)))
         (else
          (let* ((element (car parts))
                 (element-representation
                  (outer-representation-kind element))
                 (snapshot
                  (consent-number-representation-snapshot element))
                 (canonical-nonnegative-integer?
                  (and snapshot
                       (>= (string-length snapshot) 4)
                       (char=? (string-ref snapshot 1) #\I)
                       (char=? (string-ref snapshot 2) #\e)
                       (not (char=? (string-ref snapshot 3) #\-)))))
            (if (not (or snapshot (number? element)))
                #f
                (cond
             ((and canonical-nonnegative-integer?
                   (fast-list-token-within-bounds?
                    count content-size snapshot)
                   (or
                    (and (eq? representation outer-pair-marker)
                         (eq? element-representation
                              outer-number-marker))
                    (and
                     (eq? representation direct-representation-marker)
                     (eq? element-representation
                          direct-representation-marker))))
              (loop (cdr parts)
                    (cons snapshot
                          (cons memory-list-integer-part reversed))
                    (+ count 1)
                    (+ content-size (string-length snapshot))))
             ((and (eq? representation direct-representation-marker)
                   (integer? element)
                   (exact? element)
                   (>= element 0)
                   (not snapshot))
              ;; Store copied radix-16 text, never the caller's number.
              (let ((text (number->string element 16)))
                (if (fast-list-token-within-bounds?
                     count content-size text)
                    (loop
                     (cdr parts)
                     (cons (string-copy text)
                           (cons memory-list-integer-part reversed))
                     (+ count 1)
                     (+ content-size (string-length text)))
                    #f)))
                 (else #f)))))))))

;;;; Detached ordered-key validation and comparison.

(define (flat-token-rank token)
  (cond
   ((and (integer? token) (exact? token)) 0)
   ((string? token) 1)
   (else (error "invalid private memory-key token" token))))

(define (flat-token<? left right)
  "Return #t when private flat token LEFT orders before RIGHT."
  (let ((left-rank (flat-token-rank left))
        (right-rank (flat-token-rank right)))
    (cond
     ((< left-rank right-rank) #t)
     ((> left-rank right-rank) #f)
     ((= left-rank 0) (< left right))
     (else (string<? left right)))))

(define (flat-vector? value)
  "Return #t when VALUE is a validated flat descriptor vector."
  (and
   (vector? value)
   (let loop ((index 0))
     (or (= index (vector-length value))
         (and
          (let ((token (vector-ref value index)))
            (or (and (integer? token) (exact? token))
                (string? token)))
          (loop (+ index 1)))))))

(define (flat-vector<? left right)
  "Return #t when flat vector LEFT orders before RIGHT."
  (if (eq? left right)
      #f
      (let ((left-length (vector-length left))
            (right-length (vector-length right)))
        (let loop ((index 0))
          (cond
           ((= index left-length) (< left-length right-length))
           ((= index right-length) #f)
           ((flat-token<? (vector-ref left index)
                          (vector-ref right index))
            #t)
           ((flat-token<? (vector-ref right index)
                          (vector-ref left index))
            #f)
           (else (loop (+ index 1))))))))

(define (flat-vector=? left right)
  "Return #t when flat vectors LEFT and RIGHT have equal tokens."
  (or
   (eq? left right)
   (let ((length (vector-length left)))
     (and
      (= length (vector-length right))
      (let loop ((index 0))
        (if (= index length)
            #t
            (let* ((left-token (vector-ref left index))
                   (right-token (vector-ref right index))
                   (rank (flat-token-rank left-token)))
              (and
               (= rank (flat-token-rank right-token))
               (if (= rank 0)
                   (= left-token right-token)
                   (string=? left-token right-token))
               (loop (+ index 1))))))))))

(define (list-key-kind? kind)
  "Return #t when KIND denotes a detached fast-list key."
  (or (= kind memory-key-common-list-kind)
      (= kind memory-key-outer-list-kind)
      (= kind memory-key-direct-list-kind)))

(define (list-payload? value)
  "Return #t when VALUE is a validated fast-list payload."
  (and
   (vector? value)
   (= (modulo (vector-length value) 2) 0)
   (let loop ((index 0))
     (or (= index (vector-length value))
         (and
          (let ((tag (vector-ref value index)))
            (and
             (integer? tag)
             (exact? tag)
             (or (= tag memory-list-symbol-part)
                 (= tag memory-list-integer-part))))
          (string? (vector-ref value (+ index 1)))
          (loop (+ index 2)))))))

(define (list-payload<? left right)
  "Return #t when fast-list payload LEFT orders before RIGHT."
  (if (eq? left right)
      #f
      (let ((left-length (vector-length left))
            (right-length (vector-length right)))
        (let loop ((index 0))
          (cond
           ((or (= index left-length) (= index right-length))
            (< left-length right-length))
           ((< (vector-ref left index) (vector-ref right index)) #t)
           ((> (vector-ref left index) (vector-ref right index)) #f)
           ((string<? (vector-ref left (+ index 1))
                      (vector-ref right (+ index 1)))
            #t)
           ((string<? (vector-ref right (+ index 1))
                      (vector-ref left (+ index 1)))
            #f)
           (else (loop (+ index 2))))))))

(define (list-payload=? left right)
  "Return #t when fast-list payloads LEFT and RIGHT are equal."
  (or
   (eq? left right)
   (let ((length (vector-length left)))
     (and
      (= length (vector-length right))
      (let loop ((index 0))
        (or (= index length)
            (and
             (= (vector-ref left index) (vector-ref right index))
             (string=? (vector-ref left (+ index 1))
                       (vector-ref right (+ index 1)))
             (loop (+ index 2)))))))))

(define (memory-index-key? value)
  "Return #t when VALUE is a valid detached ordered-key descriptor."
  #((parameters
     (value (type any)
      (description "Possible private ordered-key sidecar.")))
    (returns (type boolean)
     (description "#t only for the complete validated flat format."))
    (effects pure))
  (and
   (vector? value)
   (= (vector-length value) 3)
   (string? (vector-ref value 0))
   (let ((kind (vector-ref value 1))
         (payload (vector-ref value 2)))
     (and
      (integer? kind)
      (exact? kind)
      (>= kind memory-key-outer-symbol-kind)
      (<= kind memory-key-general-kind)
      (cond
       ((list-key-kind? kind) (list-payload? payload))
       ((= kind memory-key-general-kind) (flat-vector? payload))
       (else (string? payload)))))))

(define (memory-index-key-sealed-wrapper? value)
  "Return #t for the constant-time facade-owned ordered-key envelope."
  #((parameters
     (value (type any)
      (description "Possible sealed internal ordered-key sidecar.")))
    (returns (type boolean)
     (description
      "#t only for a valid scope/kind/payload-container envelope."))
    (effects pure))
  (and
   (vector? value)
   (= (vector-length value) 3)
   (string? (vector-ref value 0))
   (let ((kind (vector-ref value 1))
         (payload (vector-ref value 2)))
     (and
      (integer? kind)
      (exact? kind)
      (>= kind memory-key-outer-symbol-kind)
      (<= kind memory-key-general-kind)
      (if (or (list-key-kind? kind)
              (= kind memory-key-general-kind))
          (vector? payload)
          (string? payload))))))

(define (bounded-flat-vector? value)
  "Return #t when flat VALUE has a constant-bounded comparison cost."
  (and
   (vector? value)
   (<= (vector-length value)
       (* 2 memory-fast-list-maximum-parts))
   (let loop ((index 0) (content-size 0))
     (if (= index (vector-length value))
         #t
         (let ((token (vector-ref value index)))
           (cond
            ((and (integer? token) (exact? token))
             ;; Facade-produced descriptors contain only tags, ranks,
             ;; character scalars, bytes, and quotient state ids here.
             (loop (+ index 1) content-size))
            ((string? token)
             (let ((token-size (string-length token)))
               (and
                (<= token-size memory-fast-list-maximum-token-size)
                (<= (+ content-size token-size)
                    memory-fast-list-maximum-content-size)
                (loop (+ index 1) (+ content-size token-size)))))
            (else #f)))))))

(define (memory-index-key-bounded-comparison? value)
  "Return #t when VALUE has a constant-bounded comparison payload."
  #((parameters
     (value (type any)
      (description "Possible sealed internal ordered-key sidecar.")))
    (returns (type boolean)
     (description
      "#t only when a no-hash route may compare VALUE by content."))
    (effects pure))
  (and
   (memory-index-key-sealed-wrapper? value)
   (let ((kind (vector-ref value 1))
         (payload (vector-ref value 2)))
     (cond
      ((list-key-kind? kind)
       (<= (vector-length payload)
           (* 2 memory-fast-list-maximum-parts)))
      ((= kind memory-key-general-kind)
       (bounded-flat-vector? payload))
      (else
       (<= (string-length payload)
           memory-fast-list-maximum-token-size))))))

(define (memory-index-key<? left right)
  "Return #t when validated detached key LEFT sorts before RIGHT."
  #((parameters
     (left (type vector)
      (description "Validated left ordered-key descriptor."))
     (right (type vector)
      (description "Validated right ordered-key descriptor.")))
    (returns (type boolean)
     (description "Strict total order result."))
    (effects error))
  (if (eq? left right)
      #f
      (let ((left-scope (vector-ref left 0))
        (right-scope (vector-ref right 0))
        (left-kind (vector-ref left 1))
        (right-kind (vector-ref right 1)))
        (cond
         ((string<? left-scope right-scope) #t)
         ((string<? right-scope left-scope) #f)
         ((< left-kind right-kind) #t)
         ((> left-kind right-kind) #f)
         ((list-key-kind? left-kind)
          (list-payload<? (vector-ref left 2) (vector-ref right 2)))
         ((= left-kind memory-key-general-kind)
          (flat-vector<? (vector-ref left 2) (vector-ref right 2)))
         (else
          (string<? (vector-ref left 2) (vector-ref right 2)))))))

(define (memory-index-key=? left right)
  "Return #t when validated detached keys LEFT and RIGHT are equal."
  #((parameters
     (left (type vector)
      (description "Validated left ordered-key descriptor."))
     (right (type vector)
      (description "Validated right ordered-key descriptor.")))
    (returns (type boolean)
     (description "One-pass structural equality result."))
    (effects error))
  (or
   (eq? left right)
   (let ((kind (vector-ref left 1)))
     (and
      (string=? (vector-ref left 0) (vector-ref right 0))
      (= kind (vector-ref right 1))
      (cond
       ((list-key-kind? kind)
        (list-payload=? (vector-ref left 2) (vector-ref right 2)))
       ((= kind memory-key-general-kind)
        (flat-vector=? (vector-ref left 2) (vector-ref right 2)))
       (else
        (string=? (vector-ref left 2) (vector-ref right 2))))))))

(define (memory-index-key-symbol-name key)
  "Return validated KEY's fast symbol name, or #f for another kind."
  #((parameters
     (key (type vector)
      (description "Validated detached ordered-key descriptor.")))
    (returns (type (or string false))
     (description "Copied symbol-name token or #f."))
    (effects pure))
  (let ((kind (vector-ref key 1)))
    (and (or (= kind memory-key-outer-symbol-kind)
             (= kind memory-key-direct-symbol-kind))
         (vector-ref key 2))))

(define (number-descriptor<? left right)
  "Return #t when detached number LEFT orders before RIGHT."
  (let ((left-representation (vector-ref left 0))
        (right-representation (vector-ref right 0)))
    (cond
     ((< left-representation right-representation) #t)
     ((> left-representation right-representation) #f)
     ((= left-representation number-representation-owned)
      (string<? (vector-ref left 1) (vector-ref right 1)))
     ((< (vector-ref left 1) (vector-ref right 1)) #t)
     ((> (vector-ref left 1) (vector-ref right 1)) #f)
     ((< (vector-ref left 2) (vector-ref right 2)) #t)
     ((> (vector-ref left 2) (vector-ref right 2)) #f)
     (else (string<? (vector-ref left 3) (vector-ref right 3))))))

(define (validate-persistent-representation! value representation persistent?)
  (if (and persistent?
           (eq? representation private-representation-marker)
           (not (null? value))
           (not (boolean? value)))
      (error
       "persistent memory key rejects private or raw interpreted datum"
       value)))

(define (number-atom-label value)
  "Return VALUE's detached numeric label, or #f for a nonnumber."
  (let ((number-snapshot
         (consent-number-representation-snapshot value)))
    (cond
     (number-snapshot
      (vector label-number
              (owned-number-descriptor number-snapshot)))
     ((number? value)
      (vector label-number (host-number-descriptor value)))
     (else #f))))

(define (atom-label value outer-kind persistent?)
  "Return VALUE's exact observable atom label."
  (validate-persistent-representation! value outer-kind persistent?)
  (let ((number-label (number-atom-label value)))
    (cond
     (number-label number-label)
     ((null? value) (vector label-null))
     ((boolean? value)
      (vector label-boolean (if value 1 0)))
     ((eq? outer-kind outer-character-marker)
      (vector label-outer-character (char->integer value)))
     ((consent-character? value)
      (vector label-local-character (consent-character-code value)))
     ((char? value)
      (vector label-host-character (char->integer value)))
     ((eq? outer-kind outer-symbol-marker)
      (vector label-outer-symbol (string-copy (symbol->string value))))
     ((consent-symbol? value)
      (vector label-local-symbol
              (string-copy (consent-symbol-name value))))
     ((symbol? value)
      (vector label-host-symbol (string-copy (symbol->string value))))
     ((eq? outer-kind outer-string-marker)
      (vector label-outer-string (string-copy value)))
     ((consent-datum-string? value)
      (vector label-local-string (owned-string->private-string value)))
     ((string? value)
      (vector label-host-string (string-copy value)))
     ((eq? outer-kind outer-bytevector-marker)
      (vector label-outer-bytevector
              (bytevector->private-vector value)))
     ((consent-datum-bytevector? value)
      (vector label-local-bytevector
              (owned-bytevector->private-vector value)))
     ((bytevector? value)
      (vector label-host-bytevector (bytevector->private-vector value)))
     (else (error "memory key contains a non-readable atom" value)))))

(define (number-label? label)
  "Return #t when LABEL describes a numeric atom."
  (= (vector-ref label 0) label-number))

(define (integer-vector<? left right)
  "Return #t when integer vector LEFT orders before RIGHT."
  (let ((left-length (vector-length left))
        (right-length (vector-length right)))
    (let loop ((index 0))
      (cond
       ((= index left-length) (< left-length right-length))
       ((= index right-length) #f)
       ((< (vector-ref left index) (vector-ref right index)) #t)
       ((> (vector-ref left index) (vector-ref right index)) #f)
       (else (loop (+ index 1)))))))

(define (label<? left right)
  "Return #t when observable label LEFT orders before RIGHT."
  (let ((left-tag (vector-ref left 0))
        (right-tag (vector-ref right 0)))
    (cond
     ((< left-tag right-tag) #t)
     ((> left-tag right-tag) #f)
     ((or (= left-tag label-null)
          (= left-tag label-local-pair)
          (= left-tag label-outer-pair)
          (= left-tag label-host-pair)
          (= left-tag label-local-vector-root)
          (= left-tag label-outer-vector-root)
          (= left-tag label-host-vector-root)
          (= left-tag label-vector-slot)
          (= left-tag label-vector-end))
      #f)
     ((or (= left-tag label-boolean)
          (= left-tag label-local-character)
          (= left-tag label-outer-character)
          (= left-tag label-host-character))
      (< (vector-ref left 1) (vector-ref right 1)))
     ((= left-tag label-number)
      (number-descriptor<? (vector-ref left 1)
                           (vector-ref right 1)))
     ((or (= left-tag label-local-symbol)
          (= left-tag label-outer-symbol)
          (= left-tag label-host-symbol)
          (= left-tag label-local-string)
          (= left-tag label-outer-string)
          (= left-tag label-host-string))
      (string<? (vector-ref left 1) (vector-ref right 1)))
     (else
      (integer-vector<? (vector-ref left 1)
                        (vector-ref right 1))))))

(define (label=? left right)
  "Return #t when observable labels LEFT and RIGHT are equal."
  (and (not (label<? left right))
       (not (label<? right left))))

;;;; O(V + E + C) finite term-graph snapshot.

;; A graph is #(root labels edge-0 edge-1).  Missing edges
;; are -1.  VECTOR-ROOT has edge 0 to VECTOR-SLOT or VECTOR-END; VECTOR-SLOT has
;; edge 0 to its element and edge 1 to the next slot/end.  Every other node has
;; fixed rank zero or two.
(define (datum->term-graph root persistent?)
  "Lower ROOT to a finite fixed-rank deterministic term graph."
  (let ((absent (vector 'absent))
        (owned-objects #f)
        (host-objects #f)
        (labels (make-memory-key-growable-vector))
        (edge-0 (make-memory-key-growable-vector))
        (edge-1 (make-memory-key-growable-vector))
        (pending '()))
    (define (add-node! label first second)
      "Append one labelled graph node and return its dense identifier."
      (let ((id (consent-growable-vector-append! labels label)))
        (consent-growable-vector-append! edge-0 first)
        (consent-growable-vector-append! edge-1 second)
        id))
    (define (object-ref value)
      "Return VALUE's discovered graph node, or #f when absent."
      (if (consent-datum-object? value)
          (if owned-objects
              (consent-datum-object-map-ref owned-objects value absent)
              absent)
          (if host-objects
              (consent-identity-map-ref host-objects value absent)
              absent)))
    (define (object-set! value id)
      (if (consent-datum-object? value)
          (begin
            (if (not owned-objects)
                (set! owned-objects (consent-make-datum-object-map)))
            (consent-datum-object-map-set! owned-objects value id))
          (begin
            (if (not host-objects)
                (begin
                  (if (not (consent-identity-map-fast-backend?))
                      (error
                       "memory key host compound requires fast identity map"
                       value))
                  (set! host-objects (consent-make-identity-map))))
            (consent-identity-map-set! host-objects value id))))
    (define (compound-id value label)
      "Return the memoized or newly allocated node for compound VALUE."
      (let ((known (object-ref value)))
        (if (eq? known absent)
            (let ((id (add-node! label -1 -1)))
              (object-set! value id)
              (set! pending (cons (cons id value) pending))
              id)
            known)))
    (define (intern! value)
      "Intern VALUE as one graph node and return its dense identifier."
      (let ((outer-kind (outer-representation-kind value)))
        (validate-persistent-representation!
         value outer-kind persistent?)
        (cond
         ((eq? outer-kind outer-pair-marker)
          (compound-id value (vector label-outer-pair)))
         ((eq? outer-kind outer-vector-marker)
          (compound-id value (vector label-outer-vector-root)))
         ((consent-datum-pair? value)
          (compound-id value (vector label-local-pair)))
         ((consent-datum-vector? value)
          (compound-id value (vector label-local-vector-root)))
         (else
          (cond
           ((pair? value)
            (compound-id value (vector label-host-pair)))
           ((vector? value)
            (compound-id value (vector label-host-vector-root)))
           ((or (consent-symbol? value)
                (eq? outer-kind outer-symbol-marker)
                (symbol? value)
                (consent-datum-string? value)
                (eq? outer-kind outer-string-marker)
                (string? value)
                (consent-datum-bytevector? value)
                (eq? outer-kind outer-bytevector-marker)
                (bytevector? value))
            ;; Content-scalars are identity-cached so repeated shared large
            ;; payloads are copied once per key preparation.
            (let ((known (object-ref value)))
              (if (eq? known absent)
                  (let ((id
                         (add-node!
                          (atom-label value outer-kind persistent?) -1 -1)))
                    (object-set! value id)
                    id)
                  known)))
           ((or (null? value)
                (boolean? value)
                (consent-character? value)
                (eq? outer-kind outer-character-marker)
                (char? value))
            (add-node!
             (atom-label value outer-kind persistent?) -1 -1))
           (else
            ;; A canonical number can be recognized across a source-owner
            ;; overlay only by its snapshot.  Cache every accepted nested
            ;; number by identity so shared host bignums are rendered once.
            ;; The scalar-root branch below remains cache-free; nested numbers
            ;; fail closed when a host lacks a fast identity backend.
            (let ((known (object-ref value)))
              (if (eq? known absent)
                  (let* ((label
                          (atom-label value outer-kind persistent?))
                         (id (add-node! label -1 -1)))
                    (object-set! value id)
                    id)
                  known))))))))
    (define (make-vector-chain! value)
      "Lower vector VALUE to fixed-rank slot and end nodes."
      (let ((end (add-node! (vector label-vector-end) -1 -1)))
        (let loop ((index (- (memory-vector-length value) 1)) (next end))
          (if (< index 0)
              next
              (let ((element (intern! (memory-vector-ref value index))))
                (loop (- index 1)
                      (add-node! (vector label-vector-slot)
                                 element
                                 next)))))))
    (dynamic-wind
     (lambda () #t)
     (lambda ()
       (let* ((root-kind (outer-representation-kind root))
              (root-number-label (number-atom-label root)))
         (if root-number-label
             ;; A scalar root has no identity-bearing edge.  Snapshot it
             ;; directly so canonical numbers remain usable on no-hash hosts;
             ;; nested/shared numbers still take the guarded identity cache.
             (begin
               (validate-persistent-representation!
               root root-kind persistent?)
               (vector 0
                       (vector root-number-label)
                       (vector -1)
                       (vector -1)))
             (let ((root-id (intern! root)))
               (let process ()
                 (if (not (null? pending))
                     (let* ((entry (car pending))
                            (id (car entry))
                            (value (cdr entry)))
                       (set! pending (cdr pending))
                       (if (let ((tag
                                  (vector-ref
                                   (consent-growable-vector-ref labels id) 0)))
                             (or (= tag label-local-pair)
                                 (= tag label-outer-pair)
                                 (= tag label-host-pair)))
                           (begin
                             (consent-growable-vector-set!
                              edge-0 id (intern! (memory-pair-car value)))
                             (consent-growable-vector-set!
                              edge-1 id (intern! (memory-pair-cdr value)))
                             #t)
                           (consent-growable-vector-set!
                            edge-0 id (make-vector-chain! value)))
                       (process))))
               (vector root-id
                       (consent-growable-vector-snapshot labels)
                       (consent-growable-vector-snapshot edge-0)
                       (consent-growable-vector-snapshot edge-1))))))
     (lambda ()
       (if owned-objects
           (consent-datum-object-map-release! owned-objects))))))

;;;; Dense Paige-Tarjan/Hopcroft-style smaller-half refinement.

;; Clean-room provenance: the smaller-half work bound follows Paige and
;; Tarjan, "Three Partition Refinement Algorithms", SIAM J. Comput. 16(6),
;; 973-989 (1987), DOI 10.1137/0216062.  This implementation was independently
;; structured for Consent's fixed-rank term graph; no third-party source was
;; copied or transliterated.

;; The result is #(state-block block-head block-size block-count).
(define (minimize-term-graph graph)
  "Return GRAPH's coarsest label-respecting stable partition."
  (let* ((labels (vector-ref graph 1))
         (edge-0 (vector-ref graph 2))
         (edge-1 (vector-ref graph 3))
         (state-count (vector-length labels))
         (pred-0 (make-vector state-count '()))
         (pred-1 (make-vector state-count '()))
         (state-block (make-vector state-count -1))
         (state-next (make-vector state-count -1))
         (state-prev (make-vector state-count -1))
         (block-head (make-vector state-count -1))
         (block-size (make-vector state-count 0))
         (block-pending
          (make-memory-key-dense-set
           state-count 'memory-key-block-pending))
         (marked
          (make-memory-key-dense-set
           state-count 'memory-key-refinement-mark))
         (marked-members (make-vector state-count '()))
         (marked-count (make-vector state-count 0))
         (block-count 0)
         (work (make-memory-key-worklist state-count)))
    (define (enqueue-block! block)
      "Enqueue BLOCK once as a pending partition splitter."
      (if (not (consent-dense-set-member? block-pending block))
          (begin
            (consent-dense-set-mark! block-pending block)
            (consent-worklist-push-back! work block))))
    (define (link-state! state block)
      "Insert STATE into BLOCK's intrusive member list."
      (let ((head (vector-ref block-head block)))
        (vector-set! state-block state block)
        (vector-set! state-prev state -1)
        (vector-set! state-next state head)
        (if (>= head 0) (vector-set! state-prev head state))
        (vector-set! block-head block state)
        (vector-set! block-size block
                     (+ 1 (vector-ref block-size block)))))
    (define (detach-state! state block)
      "Remove STATE from BLOCK's intrusive member list."
      (let ((previous (vector-ref state-prev state))
            (next (vector-ref state-next state)))
        (if (>= previous 0)
            (vector-set! state-next previous next)
            (vector-set! block-head block next))
        (if (>= next 0) (vector-set! state-prev next previous))
        (vector-set! state-prev state -1)
        (vector-set! state-next state -1)))
    (define (set-list-block! head block)
      "Assign every member beginning at HEAD to BLOCK."
      (let loop ((state head))
        (if (>= state 0)
            (begin
              (vector-set! state-block state block)
              (loop (vector-ref state-next state))))))
    (define (split-by-predecessors! predecessors)
      "Refine touched blocks by PREDECESSORS using smaller-half scheduling."
      (consent-dense-set-clear! marked)
      (let collect ((rest predecessors) (touched '()))
        (if (null? rest)
            (let finish ((blocks touched))
              (if (not (null? blocks))
                  (let* ((block (car blocks))
                         (members (vector-ref marked-members block))
                         (count (vector-ref marked-count block))
                         (size (vector-ref block-size block)))
                    (if (< count size)
                        (let ((marked-head -1))
                          ;; Detach the complete marked side before choosing
                          ;; identities.  The old list is now the unmarked side.
                          (let detach ((rest members))
                            (if (not (null? rest))
                                (let ((state (car rest)))
                                  (detach-state! state block)
                                  (vector-set! state-next state marked-head)
                                  (if (>= marked-head 0)
                                      (vector-set! state-prev
                                                   marked-head
                                                   state))
                                  (set! marked-head state)
                                  (detach (cdr rest)))))
                          (let* ((unmarked-head
                                  (vector-ref block-head block))
                                 (unmarked-count (- size count))
                                 (new block-count))
                            (set! block-count (+ block-count 1))
                            ;; NEW always names the smaller side.  Therefore a
                            ;; state is moved to a new block O(log V) times.
                            (if (<= count unmarked-count)
                                (begin
                                  (vector-set! block-head new marked-head)
                                  (vector-set! block-size new count)
                                  (vector-set! block-size block
                                               unmarked-count)
                                  (set-list-block! marked-head new))
                                (begin
                                  (vector-set! block-head block marked-head)
                                  (vector-set! block-size block count)
                                  (vector-set! block-head new unmarked-head)
                                  (vector-set! block-size new unmarked-count)
                                  (set-list-block! unmarked-head new)))
                            ;; If BLOCK was already pending it stays pending as
                            ;; the larger replacement; NEW supplies the other
                            ;; half.  Otherwise only the smaller half is added.
                            (enqueue-block! new))))
                    (vector-set! marked-members block '())
                    (vector-set! marked-count block 0)
                    (finish (cdr blocks)))))
            (let ((state (car rest)))
              (if (consent-dense-set-member? marked state)
                  (collect (cdr rest) touched)
                  (let* ((block (vector-ref state-block state))
                         (count (vector-ref marked-count block)))
                    (consent-dense-set-mark! marked state)
                    (vector-set! marked-members block
                                 (cons state
                                       (vector-ref marked-members block)))
                    (vector-set! marked-count block (+ count 1))
                    (collect (cdr rest)
                             (if (= count 0)
                                 (cons block touched)
                                 touched))))))))
    (dynamic-wind
     (lambda () #t)
     (lambda ()
       ;; Build reverse edge lists before any partition mutation.
       (let reverse-edges ((state 0))
         (if (< state state-count)
             (begin
               (let ((target (vector-ref edge-0 state)))
                 (if (>= target 0)
                     (vector-set!
                      pred-0 target
                      (cons state (vector-ref pred-0 target)))))
               (let ((target (vector-ref edge-1 state)))
                 (if (>= target 0)
                     (vector-set!
                      pred-1 target
                      (cons state (vector-ref pred-1 target)))))
               (reverse-edges (+ state 1)))))
       ;; Initial partitioning uses observable labels only.
       (let ((groups (make-avl-tree label<?)))
         (let group ((state 0) (tree groups))
           (if (= state state-count)
               (avl-tree-fold
                (lambda (label members ignored)
                  (let ((block block-count))
                    (set! block-count (+ block-count 1))
                    (let add ((rest members))
                      (if (not (null? rest))
                          (begin
                            (link-state! (car rest) block)
                            (add (cdr rest)))))
                    (enqueue-block! block)
                    ignored))
                #f
                tree)
               (let* ((label (vector-ref labels state))
                      (members
                       (avl-tree-ref tree label (lambda () '()))))
                 (group
                  (+ state 1)
                  (avl-tree-set tree label (cons state members)))))))
       ;; Snapshot both predecessor relations before any splitter-induced block
       ;; mutation, then refine each relation independently.
       (let refine ()
         (if (not (consent-worklist-empty? work))
             (let ((splitter (consent-worklist-pop-front! work))
                   (sources-0 '())
                   (sources-1 '()))
               (consent-dense-set-unmark! block-pending splitter)
               (let snapshot ((state (vector-ref block-head splitter)))
                 (if (>= state 0)
                     (begin
                       ;; Count and collect each incoming edge in one pass.
                       ;; Do not repeatedly append or rescan predecessor lists.
                       (let collect-0 ((incoming (vector-ref pred-0 state)))
                         (if (not (null? incoming))
                             (begin
                               (set! sources-0
                                     (cons (car incoming) sources-0))
                               (collect-0 (cdr incoming)))))
                       (let collect-1 ((incoming (vector-ref pred-1 state)))
                         (if (not (null? incoming))
                             (begin
                               (set! sources-1
                                     (cons (car incoming) sources-1))
                               (collect-1 (cdr incoming)))))
                       (snapshot (vector-ref state-next state)))))
               (split-by-predecessors! sources-0)
               (split-by-predecessors! sources-1)
               (refine))))
       (vector state-block block-head block-size block-count))
     (lambda ()
       (consent-worklist-release! work)
       (consent-dense-set-release! marked)
       (consent-dense-set-release! block-pending)))))

;;;; Canonical rooted quotient encoding.

(define (canonical-quotient graph partition)
  (let* ((root (vector-ref graph 0))
         (labels (vector-ref graph 1))
         (edge-0 (vector-ref graph 2))
         (edge-1 (vector-ref graph 3))
         (state-block (vector-ref partition 0))
         (block-head (vector-ref partition 1))
         (block-count (vector-ref partition 3))
         (canonical-id (make-vector block-count -1))
         (descriptor (make-memory-key-growable-vector))
         (pending (make-memory-key-worklist block-count))
         (next-id 1)
         (output-id 0)
         (root-block (vector-ref state-block root)))
    (define (target-id state)
      "Return STATE's canonical quotient identifier."
      (if (< state 0)
          -1
          (let* ((block (vector-ref state-block state))
                 (known (vector-ref canonical-id block)))
            (if (< known 0)
                (let ((assigned next-id))
                  (set! next-id (+ next-id 1))
                  (vector-set! canonical-id block assigned)
                  (consent-worklist-push-back! pending block)
                  assigned)
                known))))
    (define (emit-number! number)
      "Append NUMBER's flat descriptor tokens."
      (let ((representation (vector-ref number 0)))
        (consent-growable-vector-append! descriptor representation)
        (if (= representation number-representation-owned)
            (consent-growable-vector-append!
             descriptor (vector-ref number 1))
            (begin
              (consent-growable-vector-append!
               descriptor (vector-ref number 1))
              (consent-growable-vector-append!
               descriptor (vector-ref number 2))
              (consent-growable-vector-append!
               descriptor (vector-ref number 3))))))
    (define (emit-label! label)
      "Append observable LABEL's flat descriptor tokens."
      (let ((tag (vector-ref label 0)))
        (consent-growable-vector-append! descriptor tag)
        (cond
         ((= tag label-number) (emit-number! (vector-ref label 1)))
         ((or (= tag label-boolean)
              (= tag label-local-character)
              (= tag label-outer-character)
              (= tag label-host-character)
              (= tag label-local-symbol)
              (= tag label-outer-symbol)
              (= tag label-host-symbol)
              (= tag label-local-string)
              (= tag label-outer-string)
              (= tag label-host-string))
          (consent-growable-vector-append!
           descriptor (vector-ref label 1)))
         ((or (= tag label-local-bytevector)
              (= tag label-outer-bytevector)
              (= tag label-host-bytevector))
          (let ((bytes (vector-ref label 1)))
            (consent-growable-vector-append!
             descriptor (vector-length bytes))
            (let loop ((index 0))
              (if (< index (vector-length bytes))
                  (begin
                    (consent-growable-vector-append!
                     descriptor (vector-ref bytes index))
                    (loop (+ index 1))))))))))
    (dynamic-wind
     (lambda () #t)
     (lambda ()
       (vector-set! canonical-id root-block 0)
       (consent-worklist-push-back! pending root-block)
       (consent-growable-vector-append! descriptor block-count)
       (let encode ()
         (if (not (consent-worklist-empty? pending))
             (let* ((block (consent-worklist-pop-front! pending))
                    (id (vector-ref canonical-id block))
                    (state (vector-ref block-head block))
                    (label (vector-ref labels state))
                    (first (target-id (vector-ref edge-0 state)))
                    (second (target-id (vector-ref edge-1 state))))
               (if (not (= id output-id))
                   ;; Queue order and first-discovery ids are both BFS order.
                   (error
                    "canonical quotient id order mismatch" id output-id))
               (set! output-id (+ output-id 1))
               (emit-label! label)
               (if (>= first 0)
                   (consent-growable-vector-append! descriptor first))
               (if (>= second 0)
                   (consent-growable-vector-append! descriptor second))
               (encode))))
       (if (not (= next-id block-count))
           (error "unreachable quotient block" next-id block-count))
       (consent-growable-vector-snapshot descriptor))
     (lambda ()
       (consent-worklist-release! pending)
       (consent-growable-vector-release! descriptor)))))

(define (normalize-general-key value persistent?)
  "Return VALUE's canonical general-key quotient descriptor."
  (let* ((graph (datum->term-graph value persistent?))
         (partition (minimize-term-graph graph)))
    (canonical-quotient graph partition)))

(define (fast-key-payload key representation persistent?)
  "Return #(kind payload) for KEY, detaching every retained token."
  (validate-persistent-representation! key representation persistent?)
  (cond
   ((eq? representation outer-symbol-marker)
    (vector memory-key-outer-symbol-kind
            (string-copy (symbol->string key))))
   ((and (eq? representation direct-representation-marker)
         (symbol? key)
         (not (consent-symbol? key)))
    (vector memory-key-direct-symbol-kind
            (string-copy (symbol->string key))))
   ((eq? representation outer-string-marker)
    (vector memory-key-outer-string-kind (string-copy key)))
   ((and (eq? representation direct-representation-marker)
         (string? key)
         (not (consent-datum-string? key)))
    (vector memory-key-direct-string-kind (string-copy key)))
   ((null? key)
    (vector memory-key-common-list-kind (vector)))
   ((or (eq? representation outer-pair-marker)
        (and (eq? representation direct-representation-marker)
             (pair? key)
             (not (consent-datum-pair? key))))
    (let ((payload (fast-list-payload key representation)))
      (if payload
          (vector
           (if (eq? representation outer-pair-marker)
               memory-key-outer-list-kind
               memory-key-direct-list-kind)
           payload)
          (vector memory-key-general-kind
                  (normalize-general-key key persistent?)))))
   (else
    (vector memory-key-general-kind
            (normalize-general-key key persistent?)))))

(define (key-root-cacheable? key representation)
  "Return #t when a session may memoize KEY by object identity."
  ;; Cache insertion happens only after normalization accepts KEY. R7RS
  ;; requires `eq?' to be false whenever `eqv?' is false, so identity caching
  ;; cannot merge distinct accepted scalar representations.
  #t)

(define (call-with-memory-index-key-session procedure)
  "Call PROCEDURE with a dynamic-extent durable key-preparation procedure."
  "Shared roots are normalized once; only detached payloads escape the call."
  #((parameters
     (procedure (type procedure)
      (description
       "Unary procedure receiving a two-argument scope/key preparer.")))
    (returns (type object)
     (description "PROCEDURE's result."))
    (effects allocation error))
  (let ((active? #f)
        (completed? #f)
        (reentered? #f)
        (absent (vector 'absent))
        (owned-cache #f)
        (host-cache #f)
        (host-cache-alist '())
        (host-cache-alist-size 0))
    ;; Maximum compatibility identities retained by one key session.
    (define nohash-cache-maximum-size 64)
    (define (host-cache-alist-ref key)
      "Return nohash KEY's cached entry, or ABSENT."
      (let loop ((rest host-cache-alist))
        (cond
         ((null? rest) absent)
         ((eq? key (car (car rest))) (cdr (car rest)))
         (else (loop (cdr rest))))))
    (define (cache-ref key)
      "Return KEY's session entry, or ABSENT when unprepared."
      (if (consent-datum-object? key)
          (if owned-cache
              (consent-datum-object-map-ref owned-cache key absent)
              absent)
          (if (consent-identity-map-fast-backend?)
              (if host-cache
                  (consent-identity-map-ref host-cache key absent)
                  absent)
              (host-cache-alist-ref key))))
    (define (cache-set! key entry)
      (if (consent-datum-object? key)
          (begin
            (if (not owned-cache)
                (set! owned-cache (consent-make-datum-object-map)))
            (consent-datum-object-map-set! owned-cache key entry))
          (begin
            (if (consent-identity-map-fast-backend?)
                (begin
                  (if (not host-cache)
                      (set! host-cache (consent-make-identity-map)))
                  (consent-identity-map-set! host-cache key entry))
                (begin
                  (if (>= host-cache-alist-size
                          nohash-cache-maximum-size)
                      (error
                       "memory key session cache requires fast identity map"
                       key))
                  (set! host-cache-alist
                        (cons (cons key entry) host-cache-alist))
                  (set! host-cache-alist-size
                        (+ host-cache-alist-size 1)))))))
    (define (entry-descriptor entry scope-name)
      "Return ENTRY's descriptor for SCOPE-NAME, or #f."
      (let loop ((rest (vector-ref entry 1)))
        (cond
         ((null? rest) #f)
         ((string=? scope-name (car (car rest))) (cdr (car rest)))
         (else (loop (cdr rest))))))
    (define (prepare scope key)
      "Return one session-interned descriptor for SCOPE and KEY."
      (if (not active?)
          (error "memory key session preparer escaped its dynamic extent"))
      (let* ((scope-representation (outer-representation-kind scope))
             (key-representation (outer-representation-kind key)))
        (validate-persistent-representation!
         scope scope-representation #t)
        (if (not (symbol? scope))
            (error "memory key scope must be a symbol" scope))
        (let* ((scope-name (symbol->string scope))
               (cacheable?
                (key-root-cacheable? key key-representation))
               (known (if cacheable? (cache-ref key) absent))
               (entry
                (if (eq? known absent)
                    (let ((created
                           (vector
                            (fast-key-payload
                             key key-representation #t)
                            '())))
                      (if cacheable? (cache-set! key created))
                      created)
                    known))
               (cached
                (and cacheable?
                     (entry-descriptor entry scope-name))))
          (if cached
              cached
              (let* ((payload (vector-ref entry 0))
                     (descriptor
                      (vector
                       (string-copy scope-name)
                       (vector-ref payload 0)
                       (vector-ref payload 1))))
                (if cacheable?
                    (vector-set!
                     entry
                     1
                     (cons
                      (cons (vector-ref descriptor 0) descriptor)
                      (vector-ref entry 1))))
                descriptor)))))
    (dynamic-wind
     (lambda ()
       ;; Never raise from a dynamic-wind before thunk.  Hosts differ in how
       ;; much surrounding dynamic state has been restored when it signals.
       (if completed?
           (set! reentered? #t)
           (set! active? #t)))
     (lambda ()
       (let ((result (procedure prepare)))
         (if reentered?
             (error "memory key session continuation cannot reenter")
             result)))
     (lambda ()
       (set! active? #f)
       (if (not completed?)
           (begin
             (set! completed? #t)
             (if owned-cache
                 (consent-datum-object-map-release! owned-cache))))))))

(define (memory-prepare-index-key scope key)
  "Return one detached durable ordered key for SCOPE and KEY."
  #((parameters
     (scope (type symbol)
      (description "Normalized memory scope."))
     (key (type any)
      (description "Scheme-readable persistent memory key.")))
    (returns (type vector)
     (description "Detached flat ordered-key descriptor."))
    (effects allocation error))
  (let ((scope-representation (outer-representation-kind scope))
        (key-representation (outer-representation-kind key)))
    (validate-persistent-representation!
     scope scope-representation #t)
    (if (not (symbol? scope))
        (error "memory key scope must be a symbol" scope))
    (let ((payload
           (fast-key-payload key key-representation #t)))
      (vector (string-copy (symbol->string scope))
              (vector-ref payload 0)
              (vector-ref payload 1)))))


  ))
