;;; SRFI 1 list library support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 1998 Olin Shivers
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib list)' as a portable R7RS adaptation of SRFI 1:
;;; https://github.com/scheme-requests-for-implementation/srfi-1.
;;; The upstream reference implementation is MIT-licensed and descends from
;;; Olin Shivers' public reference code.  Local changes wrap the procedures in
;;; a Consent Scheme source library, keep `(scheme list)', `(srfi 1)',
;;; `(srfi srfi-1)', `(srfi :1)', and `(srfi :1 lists)' as registry aliases,
;;; and use small portable helpers instead of upstream implementation-specific
;;; optional-argument macros.

(define-library (stdlib list)
  (export xcons tree-copy list-tabulate cons*
          proper-list? circular-list? dotted-list? not-pair? null-list? list=
          circular-list length+
          iota
          first second third fourth fifth sixth seventh eighth ninth tenth
          car+cdr
          take drop take-right drop-right take! drop-right!
          split-at split-at! last last-pair
          append! concatenate concatenate!
          reverse! append-reverse append-reverse!
          zip unzip1 unzip2 unzip3 unzip4 unzip5
          count fold fold-right pair-fold pair-fold-right
          reduce reduce-right unfold unfold-right
          append-map append-map! map! pair-for-each filter-map
          map-in-order
          filter partition remove filter! partition! remove!
          find find-tail take-while drop-while take-while!
          span break span! break!
          any every list-index
          delete delete!
          delete-duplicates delete-duplicates!
          alist-cons alist-copy alist-delete alist-delete!
          lset<= lset= lset-adjoin
          lset-union lset-intersection lset-difference lset-xor
          lset-diff+intersection
          lset-union! lset-intersection! lset-difference! lset-xor!
          lset-diff+intersection!)
  (import (except (scheme base)
                  make-list list-copy map for-each
                  member memq memv assoc assq assv)
          (scheme cxr))
  (begin
    (define (xcons d a)
      "Return `(cons a d)'."
      #((parameters
         (d (type any)
          (description "Value to place in the result cdr."))
         (a (type any)
          (description "Value to place in the result car.")))
        (returns (type pair)
         (description "A pair whose car is A and whose cdr is D."))
        (effects pure))
      (cons a d))

    (define (check-non-negative-integer name value)
      "Validate VALUE as a non-negative integer for NAME."
      (if (and (integer? value) (not (negative? value)))
          value
          (error "expected non-negative integer" name value)))

    (define (check-procedure name value)
      "Validate VALUE as a procedure for NAME."
      (if (procedure? value)
          value
          (error "expected procedure" name value)))

    (define (optional name rest default)
      "Return optional REST's first value or DEFAULT."
      (cond
       ((null? rest) default)
       ((null? (cdr rest)) (car rest))
       (else (error "too many optional arguments" name rest))))

    (define (tree-copy obj)
      "Return a deep copy of OBJ's pair structure."
      #((parameters
         (obj (type any)
          (description "Object to copy recursively.")))
        (returns (type any)
         (description
          ("A recursively copied object, or OBJ itself when no compound"
           "structure is present.")))
        (effects allocation))
      (if (pair? obj)
          (cons (tree-copy (car obj)) (tree-copy (cdr obj)))
          obj))

    (define (make-list len . maybe-fill)
      "Return a list containing LEN copies of the optional fill value."
      (check-non-negative-integer 'make-list len)
      (let ((fill (optional 'make-list maybe-fill #f)))
        (let loop ((remaining len) (result '()))
          (if (= remaining 0)
              result
              (loop (- remaining 1) (cons fill result))))))

    (define (list-tabulate len proc)
      "Return a list of LEN values produced by applying PROC to each index."
      #((parameters
         (len (type exact-non-negative-integer)
          (description "Number of result elements to generate."))
         (proc (type procedure)
          (description
           "One-argument procedure applied to indexes from 0 to LEN - 1.")))
        (returns (type list)
         (description
           "List of values returned by PROC in increasing index order."))
        (effects procedure-call error))
      (check-non-negative-integer 'list-tabulate len)
      (check-procedure 'list-tabulate proc)
      (let loop ((index (- len 1)) (result '()))
        (if (< index 0)
            result
            (loop (- index 1) (cons (proc index) result)))))

    (define (cons* first . rest)
      "Return FIRST consed onto REST, using the final operand as the tail."
      #((parameters
         (first (type any)
          (description "First value in the constructed chain."))
         (rest (type list)
          (description
           "Additional operands; the final operand becomes the result tail.")))
        (returns (type any)
         (description "Nested cons structure ending in the final operand."))
        (effects allocation))
      (let loop ((value first) (rest rest))
        (if (null? rest)
            value
            (cons value (loop (car rest) (cdr rest))))))

    (define (list-copy lis)
      "Return a copy of LIS, preserving any dotted tail."
      (if (pair? lis)
          (cons (car lis) (list-copy (cdr lis)))
          lis))

    (define (last-pair lis)
      "Return the final pair of LIS."
      #((parameters
         (lis (type pair)
          (description "Non-empty list whose final pair is requested.")))
        (returns (type pair)
         (description "The last pair in LIS."))
        (effects error))
      (cond
       ((not (pair? lis)) (error "expected non-empty list" 'last-pair lis))
       ((pair? (cdr lis)) (last-pair (cdr lis)))
       (else lis)))

    (define (last lis)
      "Return the final element of LIS."
      #((parameters
         (lis (type pair)
          (description "Non-empty list whose final element is requested.")))
        (returns (type any)
         (description "The final element of LIS."))
        (effects error))
      (car (last-pair lis)))

    (define (circular-list value . values)
      "Return a circular list containing VALUE followed by VALUES."
      #((parameters
         (value (type any)
          (description "First element to include."))
         (values (type list)
          (description "Additional elements of the circular list.")))
        (returns (type pair)
         (description
           "A newly allocated circular list containing the operands."))
        (effects allocation))
      (let ((result (cons value values)))
        (set-cdr! (last-pair result) result)
        result))

    (define (proper-list? obj)
      "Return #t when OBJ is a finite proper list."
      #((parameters
         (obj (type any)
          (description "Object to inspect.")))
        (returns (type boolean)
         (description
           "Whether OBJ is a finite list ending in the empty list."))
        (effects pure))
      (let loop ((fast obj) (slow obj))
        (cond
         ((null? fast) #t)
         ((not (pair? fast)) #f)
         ((null? (cdr fast)) #t)
         ((not (pair? (cdr fast))) #f)
         (else
          (let ((fast (cdr (cdr fast)))
                (slow (cdr slow)))
            (and (not (eq? fast slow))
                 (loop fast slow)))))))

    (define (dotted-list? obj)
      "Return #t when OBJ is a finite dotted list."
      #((parameters
         (obj (type any)
          (description "Object to inspect.")))
        (returns (type boolean)
         (description
           "Whether OBJ is a finite pair chain ending in a non-list tail."))
        (effects pure))
      (let loop ((fast obj) (slow obj))
        (cond
         ((null? fast) #f)
         ((not (pair? fast)) #t)
         ((null? (cdr fast)) #f)
         ((not (pair? (cdr fast))) #t)
         (else
          (let ((fast (cdr (cdr fast)))
                (slow (cdr slow)))
            (and (not (eq? fast slow))
                 (loop fast slow)))))))

    (define (circular-list? obj)
      "Return #t when OBJ is a circular list."
      #((parameters
         (obj (type any)
          (description "Object to inspect.")))
        (returns (type boolean)
         (description "Whether OBJ is a pair chain that cycles."))
        (effects pure))
      (let loop ((fast obj) (slow obj))
        (and (pair? fast)
             (pair? (cdr fast))
             (let ((fast (cdr (cdr fast)))
                   (slow (cdr slow)))
               (or (eq? fast slow)
                   (loop fast slow))))))

    (define (not-pair? obj)
      "Return #t when OBJ is not a pair."
      #((parameters
         (obj (type any)
          (description "Object to inspect.")))
        (returns (type boolean)
         (description "Whether OBJ is not a pair."))
        (effects pure))
      (not (pair? obj)))

    (define (null-list? obj)
      "Return #t when OBJ is the empty list, erroring on non-list tails."
      #((parameters
         (obj (type any)
          (description "Object to validate as the empty tail.")))
        (returns (type boolean)
         (description "Whether OBJ is the empty list."))
        (effects error))
      (cond
       ((null? obj) #t)
       ((pair? obj) #f)
       (else (error "expected proper list tail" 'null-list? obj))))

    (define (list= equal . lists)
      "Return #t when LISTS contain equal elements under EQUAL."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Lists to compare pairwise from left to right.")))
        (returns (type boolean)
         (description "Whether every adjacent list has equal elements."))
        (effects procedure-call error))
      (check-procedure 'list= equal)
      (or (null? lists)
          (let loop ((left (car lists)) (rest (cdr lists)))
            (or (null? rest)
                (and (two-list= equal left (car rest))
                     (loop (car rest) (cdr rest)))))))

    (define (two-list= equal left right)
      "Return #t when LEFT and RIGHT contain equal elements under EQUAL."
      (cond
       ((null-list? left) (null-list? right))
       ((null-list? right) #f)
       ((equal (car left) (car right))
        (two-list= equal (cdr left) (cdr right)))
       (else #f)))

    (define (length+ lis)
      "Return LIS length, or #f when LIS is circular."
      #((parameters
         (lis (type any)
          (description "Object whose finite chain length is requested.")))
        (returns (type (or exact-non-negative-integer boolean))
         (description "Finite length of LIS, or #f when a cycle is detected."))
        (effects pure))
      (let loop ((fast lis) (slow lis) (count 0))
        (cond
         ((null? fast) count)
         ((not (pair? fast)) count)
         ((null? (cdr fast)) (+ count 1))
         ((not (pair? (cdr fast))) (+ count 1))
         (else
          (let ((fast (cdr (cdr fast)))
                (slow (cdr slow)))
            (and (not (eq? fast slow))
                 (loop fast slow (+ count 2))))))))

    (define (iota count . maybe-start-step)
      "Return COUNT numbers starting at START and stepping by STEP."
      #((parameters
         (count (type exact-non-negative-integer)
          (description "Number of values to produce."))
         (maybe-start-step (type list)
          (description "Optional start value and step value.")))
        (returns (type list)
         (description "A list of COUNT arithmetic progression values."))
        (effects error))
      (check-non-negative-integer 'iota count)
      (let ((start (if (null? maybe-start-step) 0 (car maybe-start-step)))
            (step (if (or (null? maybe-start-step)
                          (null? (cdr maybe-start-step)))
                      1
                      (cadr maybe-start-step))))
        (if (and (pair? maybe-start-step)
                 (pair? (cdr maybe-start-step))
                 (pair? (cddr maybe-start-step)))
            (error "too many optional arguments" 'iota maybe-start-step))
        (let loop ((index (- count 1)) (result '()))
          (if (< index 0)
              result
              (loop (- index 1)
                    (cons (+ start (* index step)) result))))))

    (define (first lis)
      "Return the first element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose first element is requested.")))
        (returns (type any)
         (description "The first element of LIS."))
        (effects error))
      (car lis))

    (define (second lis)
      "Return the second element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose second element is requested.")))
        (returns (type any)
         (description "The second element of LIS."))
        (effects error))
      (cadr lis))

    (define (third lis)
      "Return the third element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose third element is requested.")))
        (returns (type any)
         (description "The third element of LIS."))
        (effects error))
      (caddr lis))

    (define (fourth lis)
      "Return the fourth element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose fourth element is requested.")))
        (returns (type any)
         (description "The fourth element of LIS."))
        (effects error))
      (cadddr lis))

    (define (fifth lis)
      "Return the fifth element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose fifth element is requested.")))
        (returns (type any)
         (description "The fifth element of LIS."))
        (effects error))
      (car (cddddr lis)))

    (define (sixth lis)
      "Return the sixth element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose sixth element is requested.")))
        (returns (type any)
         (description "The sixth element of LIS."))
        (effects error))
      (cadr (cddddr lis)))

    (define (seventh lis)
      "Return the seventh element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose seventh element is requested.")))
        (returns (type any)
         (description "The seventh element of LIS."))
        (effects error))
      (caddr (cddddr lis)))

    (define (eighth lis)
      "Return the eighth element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose eighth element is requested.")))
        (returns (type any)
         (description "The eighth element of LIS."))
        (effects error))
      (cadddr (cddddr lis)))

    (define (ninth lis)
      "Return the ninth element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose ninth element is requested.")))
        (returns (type any)
         (description "The ninth element of LIS."))
        (effects error))
      (car (cddddr (cddddr lis))))

    (define (tenth lis)
      "Return the tenth element of LIS."
      #((parameters
         (lis (type pair)
          (description "List whose tenth element is requested.")))
        (returns (type any)
         (description "The tenth element of LIS."))
        (effects error))
      (cadr (cddddr (cddddr lis))))

    (define (car+cdr pair)
      "Return PAIR's car and cdr as two values."
      #((parameters
         (pair (type pair)
          (description "Pair to decompose.")))
        (returns (type (values any any))
         (description "Two values: PAIR's car and PAIR's cdr."))
        (effects error))
      (values (car pair) (cdr pair)))

    (define (take lis count)
      "Return the first COUNT elements of LIS."
      #((parameters
         (lis (type list)
          (description "List to copy from the front."))
         (count (type exact-non-negative-integer)
          (description "Number of elements to take.")))
        (returns (type list)
         (description "Fresh list containing the first COUNT elements."))
        (effects error))
      (check-non-negative-integer 'take count)
      (let loop ((rest lis) (remaining count))
        (if (= remaining 0)
            '()
            (cons (car rest)
                  (loop (cdr rest) (- remaining 1))))))

    (define (drop lis count)
      "Return LIS without its first COUNT elements."
      #((parameters
         (lis (type list)
          (description "List whose prefix is skipped."))
         (count (type exact-non-negative-integer)
          (description "Number of elements to drop.")))
        (returns (type any)
         (description "Tail of LIS after COUNT cdr steps."))
        (effects error))
      (check-non-negative-integer 'drop count)
      (let loop ((rest lis) (remaining count))
        (if (= remaining 0)
            rest
            (loop (cdr rest) (- remaining 1)))))

    (define (take-right lis count)
      "Return the final COUNT elements of LIS."
      #((parameters
         (lis (type list)
          (description "List whose suffix is requested."))
         (count (type exact-non-negative-integer)
          (description "Number of trailing elements to keep.")))
        (returns (type any)
         (description "Tail of LIS containing the final COUNT elements."))
        (effects error))
      (check-non-negative-integer 'take-right count)
      (let loop ((lag lis) (lead (drop lis count)))
        (if (pair? lead)
            (loop (cdr lag) (cdr lead))
            lag)))

    (define (drop-right lis count)
      "Return LIS without its final COUNT elements."
      #((parameters
         (lis (type list)
          (description "List whose suffix is dropped."))
         (count (type exact-non-negative-integer)
          (description "Number of trailing elements to remove.")))
        (returns (type list)
         (description "Fresh prefix of LIS without the final COUNT elements."))
        (effects error))
      (check-non-negative-integer 'drop-right count)
      (let loop ((lag lis) (lead (drop lis count)))
        (if (pair? lead)
            (cons (car lag) (loop (cdr lag) (cdr lead)))
            '())))

    (define (take! lis count)
      "Destructively truncate LIS to COUNT elements when practical."
      #((parameters
         (lis (type list)
          (description "List to truncate in place."))
         (count (type exact-non-negative-integer)
          (description "Number of leading elements to keep.")))
        (returns (type list)
         (description "LIS truncated to COUNT elements, or the empty list."))
        (effects state-write error))
      (check-non-negative-integer 'take! count)
      (if (= count 0)
          '()
          (begin
            (set-cdr! (drop lis (- count 1)) '())
            lis)))

    (define (drop-right! lis count)
      "Destructively drop LIS's final COUNT elements when practical."
      #((parameters
         (lis (type list)
          (description "List to truncate in place."))
         (count (type exact-non-negative-integer)
          (description "Number of trailing elements to remove.")))
        (returns (type list)
         (description "LIS without its final COUNT elements when possible."))
        (effects state-write error))
      (check-non-negative-integer 'drop-right! count)
      (if (= count 0)
          lis
          (let ((prefix-length (- (length lis) count)))
            (if (<= prefix-length 0)
                '()
                (take! lis prefix-length)))))

    (define (split-at lis count)
      "Return two values: the first COUNT elements and the remaining tail."
      #((parameters
         (lis (type list)
          (description "List to split."))
         (count (type exact-non-negative-integer)
          (description "Number of leading elements in the prefix.")))
        (returns (type (values list any))
         (description "Two values: a fresh prefix and the remaining tail."))
        (effects error))
      (values (take lis count) (drop lis count)))

    (define (split-at! lis count)
      "Destructively split LIS at COUNT when practical."
      #((parameters
         (lis (type list)
          (description "List to split in place."))
         (count (type exact-non-negative-integer)
          (description "Number of leading elements in the prefix.")))
        (returns (type (values list any))
         (description "Two values: the prefix and the remaining tail."))
        (effects state-write error))
      (if (= count 0)
          (values '() lis)
          ;; R7RS does not specify `let' initializer order.  Capture the tail
          ;; before truncating LIS so every host returns the original suffix.
          (let* ((tail (drop lis count))
                 (prefix (take! lis count)))
            (values prefix tail))))

    (define (append! . lists)
      "Return LISTS appended, destructively joining non-empty prefixes."
      #((parameters
         (lists (type list)
          (description "Lists to append, reusing non-empty prefixes.")))
        (returns (type any)
         (description "The appended result."))
        (effects state-write))
      (let loop ((lists lists))
        (cond
         ((null? lists) '())
         ((null? (cdr lists)) (car lists))
         ((null? (car lists)) (loop (cdr lists)))
         (else
          (let ((head (car lists)))
            (set-cdr! (last-pair head) (loop (cdr lists)))
            head)))))

    (define (concatenate lists)
      "Append a list of LISTS."
      #((parameters
         (lists (type list)
          (description "List whose elements are appended in order.")))
        (returns (type any)
         (description "The appended result."))
        (effects allocation))
      (apply append lists))

    (define (concatenate! lists)
      "Append a list of LISTS, destructively joining when practical."
      #((parameters
         (lists (type list)
          (description "List whose elements are appended in order.")))
        (returns (type any)
         (description "The appended result."))
        (effects state-write))
      (apply append! lists))

    (define (reverse! lis)
      "Destructively reverse LIS."
      #((parameters
         (lis (type list)
          (description "List to reverse in place.")))
        (returns (type list)
         (description "LIS with its links reversed."))
        (effects state-write error))
      (let loop ((rest lis) (result '()))
        (if (null-list? rest)
            result
            (let ((tail (cdr rest)))
              (set-cdr! rest result)
              (loop tail rest)))))

    (define (append-reverse rev-head tail)
      "Append `(reverse rev-head)' to TAIL."
      #((parameters
         (rev-head (type list)
          (description "List to reverse before appending."))
         (tail (type any)
          (description "Tail attached after the reversed prefix.")))
        (returns (type any)
         (description "A fresh reversed prefix followed by TAIL."))
        (effects allocation))
      (append (reverse rev-head) tail))

    (define (append-reverse! rev-head tail)
      "Destructively append `(reverse rev-head)' to TAIL."
      #((parameters
         (rev-head (type list)
          (description "List to reverse in place before appending."))
         (tail (type any)
          (description "Tail attached after the reversed prefix.")))
        (returns (type any)
         (description "REV-HEAD reversed onto TAIL."))
        (effects state-write error))
      (let loop ((rest rev-head) (result tail))
        (if (null-list? rest)
            result
            (let ((tail (cdr rest)))
              (set-cdr! rest result)
              (loop tail rest)))))

    (define (any-null? lists)
      "Return #t when any list in LISTS is empty."
      (cond
       ((null? lists) #f)
       ((null-list? (car lists)) #t)
       (else (any-null? (cdr lists)))))

    (define (cars lists)
      "Return the cars of LISTS."
      (if (null? lists)
          '()
          (cons (car (car lists)) (cars (cdr lists)))))

    (define (cdrs lists)
      "Return the cdrs of LISTS."
      (if (null? lists)
          '()
          (cons (cdr (car lists)) (cdrs (cdr lists)))))

    (define (zip list1 . more-lists)
      "Zip LIST1 and MORE-LISTS into tuples."
      #((parameters
         (list1 (type list)
          (description "First list supplying tuple elements."))
         (more-lists (type list)
          (description "Additional lists supplying tuple elements.")))
        (returns (type list)
         (description "List of tuples, one tuple per parallel position."))
        (effects allocation))
      (apply map list list1 more-lists))

    (define (unzip1 tuples)
      "Return the first field from each tuple."
      #((parameters
         (tuples (type list)
          (description "List of tuples to project.")))
        (returns (type list)
         (description "List of first fields."))
        (effects error))
      (map car tuples))

    (define (unzip2 tuples)
      "Return two values from a list of two-field tuples."
      #((parameters
         (tuples (type list)
          (description "List of tuples to project.")))
        (returns (type (values list list))
         (description "Two values containing the first and second fields."))
        (effects error))
      (values (map car tuples) (map cadr tuples)))

    (define (unzip3 tuples)
      "Return three values from a list of three-field tuples."
      #((parameters
         (tuples (type list)
          (description "List of tuples to project.")))
        (returns (type (values list list list))
         (description "Three values containing the projected fields."))
        (effects error))
      (values (map car tuples) (map cadr tuples) (map caddr tuples)))

    (define (unzip4 tuples)
      "Return four values from a list of four-field tuples."
      #((parameters
         (tuples (type list)
          (description "List of tuples to project.")))
        (returns (type (values list list list list))
         (description "Four values containing the projected fields."))
        (effects error))
      (values (map car tuples) (map cadr tuples) (map caddr tuples)
              (map cadddr tuples)))

    (define (unzip5 tuples)
      "Return five values from a list of five-field tuples."
      #((parameters
         (tuples (type list)
          (description "List of tuples to project.")))
        (returns (type (values list list list list list))
         (description "Five values containing the projected fields."))
        (effects error))
      (values (map car tuples) (map cadr tuples) (map caddr tuples)
              (map cadddr tuples) (map fifth tuples)))

    (define (count pred lis1 . lists)
      "Count elements satisfying PRED across one or more lists."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each parallel element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type exact-non-negative-integer)
         (description "Number of positions for which PRED returns true."))
        (effects procedure-call error))
      (check-procedure 'count pred)
      (apply fold
             (lambda args
               (let ((elements (drop-right args 1))
                     (total (last args)))
                 (if (apply pred elements) (+ total 1) total)))
             0
             lis1
             lists))

    (define (fold kons knil lis1 . lists)
      "Left-fold KONS over LIS1 and optional parallel LISTS."
      #((parameters
         (kons (type procedure)
          (description
            "Combiner receiving elements followed by the accumulator."))
         (knil (type any)
          (description "Initial accumulator."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Final accumulator."))
        (effects procedure-call error))
      (check-procedure 'fold kons)
      (let loop ((all-lists (cons lis1 lists)) (result knil))
        (if (any-null? all-lists)
            result
            (loop (cdrs all-lists)
                  (apply kons
                         (append (cars all-lists) (list result)))))))

    (define (fold-right kons knil lis1 . lists)
      "Right-fold KONS over LIS1 and optional parallel LISTS."
      #((parameters
         (kons (type procedure)
          (description
            "Combiner receiving elements followed by the accumulator."))
         (knil (type any)
          (description "Initial rightmost accumulator."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Final accumulator."))
        (effects procedure-call error))
      (check-procedure 'fold-right kons)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            knil
            (apply kons
                   (append (cars all-lists)
                           (list (loop (cdrs all-lists))))))))

    (define (pair-fold kons knil lis1 . lists)
      "Left-fold KONS over the pair tails of one or more lists."
      #((parameters
         (kons (type procedure)
          (description "Combiner receiving current tails and accumulator."))
         (knil (type any)
          (description "Initial accumulator."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Final accumulator."))
        (effects procedure-call error))
      (check-procedure 'pair-fold kons)
      (let loop ((all-lists (cons lis1 lists)) (result knil))
        (if (any-null? all-lists)
            result
            (loop (cdrs all-lists)
                  (apply kons (append all-lists (list result)))))))

    (define (pair-fold-right kons knil lis1 . lists)
      "Right-fold KONS over the pair tails of one or more lists."
      #((parameters
         (kons (type procedure)
          (description "Combiner receiving current tails and accumulator."))
         (knil (type any)
          (description "Initial rightmost accumulator."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Final accumulator."))
        (effects procedure-call error))
      (check-procedure 'pair-fold-right kons)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            knil
            (apply kons
                   (append all-lists
                           (list (loop (cdrs all-lists))))))))

    (define (reduce proc identity lis)
      "Reduce LIS with PROC, returning IDENTITY for an empty list."
      #((parameters
         (proc (type procedure)
          (description "Two-argument reduction procedure."))
         (identity (type any)
          (description "Value returned when LIS is empty."))
         (lis (type list)
          (description "List to reduce.")))
        (returns (type any)
         (description "Reduction result."))
        (effects procedure-call error))
      (check-procedure 'reduce proc)
      (if (null-list? lis)
          identity
          (fold proc (car lis) (cdr lis))))

    (define (reduce-right proc identity lis)
      "Right-reduce LIS with PROC, returning IDENTITY for an empty list."
      #((parameters
         (proc (type procedure)
          (description "Two-argument reduction procedure."))
         (identity (type any)
          (description "Value returned when LIS is empty."))
         (lis (type list)
          (description "List to reduce from the right.")))
        (returns (type any)
         (description "Reduction result."))
        (effects procedure-call error))
      (check-procedure 'reduce-right proc)
      (if (null-list? lis)
          identity
          (fold-right proc (last lis) (drop-right lis 1))))

    (define (unfold stop? mapper successor seed . maybe-tail-gen)
      "Generate a list from SEED until STOP? is true."
      #((parameters
         (stop? (type procedure)
          (description "Predicate deciding when generation stops."))
         (mapper (type procedure)
          (description "Procedure mapping each seed to an element."))
         (successor (type procedure)
          (description "Procedure producing the next seed."))
         (seed (type any)
          (description "Initial seed value."))
         (maybe-tail-gen (type list)
          (description "Optional procedure producing the final tail.")))
        (returns (type list)
         (description "Generated list."))
        (effects procedure-call))
      (let ((tail-gen (optional 'unfold maybe-tail-gen (lambda (seed) '()))))
        (if (stop? seed)
            (tail-gen seed)
            (cons (mapper seed)
                  (unfold stop? mapper successor (successor seed)
                          tail-gen)))))

    (define (unfold-right stop? mapper successor seed . maybe-tail)
      "Generate a right-folded list from SEED until STOP? is true."
      #((parameters
         (stop? (type procedure)
          (description "Predicate deciding when generation stops."))
         (mapper (type procedure)
          (description "Procedure mapping each seed to an element."))
         (successor (type procedure)
          (description "Procedure producing the next seed."))
         (seed (type any)
          (description "Initial seed value."))
         (maybe-tail (type list)
          (description "Optional tail value for the generated result.")))
        (returns (type list)
         (description "Generated list."))
        (effects procedure-call))
      (let ((tail (optional 'unfold-right maybe-tail '())))
        (let loop ((seed seed) (result tail))
          (if (stop? seed)
              result
              (loop (successor seed)
                    (cons (mapper seed) result))))))

    (define (map proc lis1 . lists)
      "Map PROC over LIS1 and optional parallel LISTS."
      (check-procedure 'map proc)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            '()
            (cons (apply proc (cars all-lists))
                  (loop (cdrs all-lists))))))

    (define (for-each proc lis1 . lists)
      "Apply PROC for side effects across one or more lists."
      (check-procedure 'for-each proc)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            #t
            (begin
              (apply proc (cars all-lists))
              (loop (cdrs all-lists))))))

    (define (append-map proc lis1 . lists)
      "Map PROC over lists and append the resulting lists."
      #((parameters
         (proc (type procedure)
          (description "Procedure producing a list for each element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Appended mapped result."))
        (effects procedure-call allocation error))
      (apply append (apply map proc lis1 lists)))

    (define (append-map! proc lis1 . lists)
      "Map PROC over lists and destructively append the resulting lists."
      #((parameters
         (proc (type procedure)
          (description "Procedure producing a list for each element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Appended mapped result."))
        (effects procedure-call state-write error))
      (apply append! (apply map proc lis1 lists)))

    (define (map! proc lis1 . lists)
      "Destructively replace LIS1's elements with PROC results."
      #((parameters
         (proc (type procedure)
          (description "Procedure producing replacement elements."))
         (lis1 (type list)
          (description "List updated in place."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type list)
         (description "LIS1 after its elements are replaced."))
        (effects procedure-call state-write error))
      (check-procedure 'map! proc)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            lis1
            (begin
              (set-car! (car all-lists) (apply proc (cars all-lists)))
              (loop (cdrs all-lists))))))

    (define (pair-for-each proc lis1 . lists)
      "Apply PROC to pair tails across one or more lists."
      #((parameters
         (proc (type procedure)
          (description "Procedure invoked with current tails."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type boolean)
         (description "#t after PROC has been applied to each position."))
        (effects procedure-call error))
      (check-procedure 'pair-for-each proc)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            #t
            (begin
              (apply proc all-lists)
              (loop (cdrs all-lists))))))

    (define (filter-map proc lis1 . lists)
      "Map PROC and collect its true results."
      #((parameters
         (proc (type procedure)
          (description "Procedure applied to each parallel element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type list)
         (description "True results produced by PROC."))
        (effects procedure-call allocation error))
      (check-procedure 'filter-map proc)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            '()
            (let ((value (apply proc (cars all-lists))))
              (if value
                  (cons value (loop (cdrs all-lists)))
                  (loop (cdrs all-lists)))))))

    (define (map-in-order proc lis1 . lists)
      "Map PROC over LIS1 and LISTS from left to right."
      #((parameters
         (proc (type procedure)
          (description "Procedure applied to each parallel element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type list)
         (description "List of PROC results in traversal order."))
        (effects procedure-call allocation error))
      (check-procedure 'map-in-order proc)
      (let loop ((all-lists (cons lis1 lists)))
        (if (any-null? all-lists)
            '()
            ;; Bind both calls explicitly: R7RS leaves argument evaluation
            ;; order unspecified, while this procedure promises left-to-right
            ;; effects.
            (let* ((value (apply proc (cars all-lists)))
                   (rest (loop (cdrs all-lists))))
              (cons value rest)))))

    (define (filter pred lis)
      "Return LIS elements satisfying PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to filter.")))
        (returns (type list)
         (description "Fresh list of elements for which PRED returns true."))
        (effects procedure-call allocation error))
      (check-procedure 'filter pred)
      (let loop ((rest lis))
        (cond
         ((null-list? rest) '())
         ((pred (car rest)) (cons (car rest) (loop (cdr rest))))
         (else (loop (cdr rest))))))

    (define (partition pred lis)
      "Return two values: elements satisfying PRED and the remaining elements.\
"
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to partition.")))
        (returns (type (values list list))
         (description
          "Two fresh lists: accepted elements and rejected elements."))
        (effects procedure-call allocation error))
      (check-procedure 'partition pred)
      (let loop ((rest lis))
        (if (null-list? rest)
            (values '() '())
            (call-with-values
             (lambda () (loop (cdr rest)))
             (lambda (in out)
               (if (pred (car rest))
                   (values (cons (car rest) in) out)
                   (values in (cons (car rest) out))))))))

    (define (remove pred lis)
      "Return LIS without elements satisfying PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to filter.")))
        (returns (type list)
         (description "Fresh list of elements for which PRED returns #f."))
        (effects procedure-call allocation error))
      (filter (lambda (value) (not (pred value))) lis))

    (define (filter! pred lis)
      "Destructively filter LIS when practical."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to filter.")))
        (returns (type list)
         (description "Elements for which PRED returns true."))
        (effects procedure-call allocation error))
      (filter pred lis))

    (define (partition! pred lis)
      "Destructively partition LIS when practical."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to partition.")))
        (returns (type (values list list))
         (description "Two values: accepted elements and rejected elements."))
        (effects procedure-call allocation error))
      (partition pred lis))

    (define (remove! pred lis)
      "Destructively remove matching elements when practical."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to filter.")))
        (returns (type list)
         (description "Elements for which PRED returns #f."))
        (effects procedure-call allocation error))
      (remove pred lis))

    (define (find pred lis)
      "Return the first element in LIS satisfying PRED, or #f."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to search.")))
        (returns (type (or any boolean))
         (description "Matching element, or #f when none matches."))
        (effects procedure-call error))
      (let ((tail (find-tail pred lis)))
        (and tail (car tail))))

    (define (find-tail pred lis)
      "Return the first pair whose car satisfies PRED, or #f."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to search.")))
        (returns (type (or pair boolean))
         (description "Matching tail pair, or #f when none matches."))
        (effects procedure-call error))
      (check-procedure 'find-tail pred)
      (let loop ((rest lis))
        (cond
         ((null-list? rest) #f)
         ((pred (car rest)) rest)
         (else (loop (cdr rest))))))

    (define (take-while pred lis)
      "Return the longest prefix of LIS whose elements satisfy PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List whose prefix is copied.")))
        (returns (type list)
         (description "Fresh prefix of elements satisfying PRED."))
        (effects procedure-call allocation error))
      (check-procedure 'take-while pred)
      (let loop ((rest lis))
        (cond
         ((null-list? rest) '())
         ((pred (car rest)) (cons (car rest) (loop (cdr rest))))
         (else '()))))

    (define (drop-while pred lis)
      "Drop the longest prefix of LIS whose elements satisfy PRED."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List whose prefix is skipped.")))
        (returns (type list)
         (description "Remaining suffix after dropping matching elements."))
        (effects procedure-call error))
      (check-procedure 'drop-while pred)
      (let loop ((rest lis))
        (cond
         ((null-list? rest) '())
         ((pred (car rest)) (loop (cdr rest)))
         (else rest))))

    (define (take-while! pred lis)
      "Destructively keep the longest prefix satisfying PRED when practical."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to truncate in place.")))
        (returns (type list)
         (description "Prefix of elements satisfying PRED."))
        (effects procedure-call state-write error))
      (let ((prefix (take-while pred lis)))
        (if (null? prefix)
            '()
            (take! lis (length prefix)))))

    (define (span pred lis)
      "Return prefix satisfying PRED and the remaining suffix."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to split at the first rejected element.")))
        (returns (type (values list list))
         (description "Two values: matching prefix and remaining suffix."))
        (effects procedure-call allocation error))
      (values (take-while pred lis) (drop-while pred lis)))

    (define (break pred lis)
      "Return prefix not satisfying PRED and the remaining suffix."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to split at the first accepted element.")))
        (returns (type (values list list))
         (description "Two values: rejected prefix and remaining suffix."))
        (effects procedure-call allocation error))
      (span (lambda (value) (not (pred value))) lis))

    (define (span! pred lis)
      "Destructively span LIS when practical."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to split in place.")))
        (returns (type (values list list))
         (description "Two values: matching prefix and remaining suffix."))
        (effects procedure-call state-write error))
      (let ((prefix (take-while pred lis)))
        (if (null? prefix)
            (values '() lis)
            (let* ((count (length prefix))
                   (suffix (drop lis count))
                   (prefix (take! lis count)))
              (values prefix suffix)))))

    (define (break! pred lis)
      "Destructively break LIS when practical."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each element."))
         (lis (type list)
          (description "List to split in place.")))
        (returns (type (values list list))
         (description "Two values: rejected prefix and remaining suffix."))
        (effects procedure-call state-write error))
      (span! (lambda (value) (not (pred value))) lis))

    (define (any pred lis1 . lists)
      "Return the first true result of applying PRED across the lists."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each parallel element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "First true predicate result, or #f."))
        (effects procedure-call error))
      (check-procedure 'any pred)
      (let loop ((all-lists (cons lis1 lists)))
        (and (not (any-null? all-lists))
             (or (apply pred (cars all-lists))
                 (loop (cdrs all-lists))))))

    (define (every pred lis1 . lists)
      "Return #f on the first false PRED result, else the last true result."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each parallel element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type any)
         (description "Last true predicate result, or #f."))
        (effects procedure-call error))
      (check-procedure 'every pred)
      (let loop ((all-lists (cons lis1 lists)) (last-value #t))
        (if (any-null? all-lists)
            last-value
            (let ((value (apply pred (cars all-lists))))
              (and value (loop (cdrs all-lists) value))))))

    (define (list-index pred lis1 . lists)
      "Return the first index satisfying PRED, or #f."
      #((parameters
         (pred (type procedure)
          (description "Predicate applied to each parallel element group."))
         (lis1 (type list)
          (description "First list to traverse."))
         (lists (type list)
          (description "Additional lists to traverse in parallel.")))
        (returns (type (or exact-non-negative-integer boolean))
         (description "First matching zero-based index, or #f."))
        (effects procedure-call error))
      (check-procedure 'list-index pred)
      (let loop ((all-lists (cons lis1 lists)) (index 0))
        (and (not (any-null? all-lists))
             (if (apply pred (cars all-lists))
                 index
                 (loop (cdrs all-lists) (+ index 1))))))

    (define (member obj lis . maybe-equal)
      "Return the first tail of LIS whose car equals OBJ."
      (let ((equal (optional 'member maybe-equal equal?)))
        (find-tail (lambda (value) (equal obj value)) lis)))

    (define (memq obj lis)
      "Return the first tail of LIS whose car is `eq?' to OBJ."
      (member obj lis eq?))

    (define (memv obj lis)
      "Return the first tail of LIS whose car is `eqv?' to OBJ."
      (member obj lis eqv?))

    (define (delete obj lis . maybe-equal)
      "Return LIS with elements equal to OBJ removed."
      #((parameters
         (obj (type any)
          (description "Element to remove."))
         (lis (type list)
          (description "List to filter."))
         (maybe-equal (type list)
          (description "Optional two-argument equality predicate.")))
        (returns (type list)
         (description "Fresh list without elements equal to OBJ."))
        (effects procedure-call allocation error))
      (let ((equal (optional 'delete maybe-equal equal?)))
        (filter (lambda (value) (not (equal obj value))) lis)))

    (define (delete! obj lis . maybe-equal)
      "Destructively delete elements equal to OBJ when practical."
      #((parameters
         (obj (type any)
          (description "Element to remove."))
         (lis (type list)
          (description "List to filter."))
         (maybe-equal (type list)
          (description "Optional two-argument equality predicate.")))
        (returns (type list)
         (description "Elements not equal to OBJ."))
        (effects procedure-call allocation error))
      (apply delete obj lis maybe-equal))

    (define (delete-duplicates lis . maybe-equal)
      "Return LIS with later duplicate elements removed."
      #((parameters
         (lis (type list)
          (description "List to deduplicate."))
         (maybe-equal (type list)
          (description "Optional two-argument equality predicate.")))
        (returns (type list)
         (description "Fresh list keeping each element's first occurrence."))
        (effects procedure-call allocation error))
      (let ((equal (optional 'delete-duplicates maybe-equal equal?)))
        (let loop ((rest lis))
          (if (null-list? rest)
              '()
              (cons (car rest)
                    (loop (delete (car rest) (cdr rest) equal)))))))

    (define (delete-duplicates! lis . maybe-equal)
      "Destructively delete later duplicate elements when practical."
      #((parameters
         (lis (type list)
          (description "List to deduplicate."))
         (maybe-equal (type list)
          (description "Optional two-argument equality predicate.")))
        (returns (type list)
         (description "Elements with later duplicates removed."))
        (effects procedure-call allocation error))
      (apply delete-duplicates lis maybe-equal))

    (define (assoc obj alist . maybe-equal)
      "Return the first pair in ALIST whose car equals OBJ."
      (let ((equal (optional 'assoc maybe-equal equal?)))
        (find (lambda (entry) (equal obj (car entry))) alist)))

    (define (assq obj alist)
      "Return the first pair in ALIST whose car is `eq?' to OBJ."
      (assoc obj alist eq?))

    (define (assv obj alist)
      "Return the first pair in ALIST whose car is `eqv?' to OBJ."
      (assoc obj alist eqv?))

    (define (alist-cons key datum alist)
      "Add KEY and DATUM to ALIST."
      #((parameters
         (key (type any)
          (description "Key for the new association."))
         (datum (type any)
          (description "Value for the new association."))
         (alist (type list)
          (description "Association list to extend.")))
        (returns (type list)
         (description "ALIST with the new association at the front."))
        (effects allocation))
      (cons (cons key datum) alist))

    (define (alist-copy alist)
      "Return a fresh copy of ALIST's top-level pairs."
      #((parameters
         (alist (type list)
          (description "Association list to copy.")))
        (returns (type list)
         (description "Fresh association list with copied entries."))
        (effects allocation error))
      (map (lambda (entry) (cons (car entry) (cdr entry))) alist))

    (define (alist-delete key alist . maybe-equal)
      "Return ALIST without entries whose key equals KEY."
      #((parameters
         (key (type any)
          (description "Key to remove."))
         (alist (type list)
          (description "Association list to filter."))
         (maybe-equal (type list)
          (description "Optional two-argument equality predicate.")))
        (returns (type list)
         (description "Fresh association list without matching keys."))
        (effects procedure-call allocation error))
      (let ((equal (optional 'alist-delete maybe-equal equal?)))
        (filter (lambda (entry) (not (equal key (car entry)))) alist)))

    (define (alist-delete! key alist . maybe-equal)
      "Destructively delete ALIST entries when practical."
      #((parameters
         (key (type any)
          (description "Key to remove."))
         (alist (type list)
          (description "Association list to filter."))
         (maybe-equal (type list)
          (description "Optional two-argument equality predicate.")))
        (returns (type list)
         (description "Association list without matching keys."))
        (effects procedure-call allocation error))
      (apply alist-delete key alist maybe-equal))

    (define (lset<= equal . lists)
      "Return #t when each list is a subset of the next list."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Lists compared as mathematical sets.")))
        (returns (type boolean)
         (description "Whether each list is a subset of the next."))
        (effects procedure-call error))
      (check-procedure 'lset<= equal)
      (or (null? lists)
          (let loop ((left (car lists)) (rest (cdr lists)))
            (or (null? rest)
                (and (every (lambda (value)
                              (member value (car rest) equal))
                            left)
                     (loop (car rest) (cdr rest)))))))

    (define (lset= equal . lists)
      "Return #t when LISTS contain the same set of elements."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Lists compared as mathematical sets.")))
        (returns (type boolean)
         (description "Whether all lists contain the same set of elements."))
        (effects procedure-call error))
      (check-procedure 'lset= equal)
      (or (null? lists)
          (let loop ((left (car lists)) (rest (cdr lists)))
            (or (null? rest)
                (and (lset<= equal left (car rest))
                     (lset<= equal (car rest) left)
                     (loop (car rest) (cdr rest)))))))

    (define (lset-adjoin equal lis . values)
      "Return LIS with VALUES adjoined under EQUAL."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis (type list)
          (description "Base set list."))
         (values (type list)
          (description "Elements to add when absent.")))
        (returns (type list)
         (description "Set list containing LIS and any new VALUES."))
        (effects procedure-call allocation error))
      (check-procedure 'lset-adjoin equal)
      (fold (lambda (value result)
              (if (member value result equal)
                  result
                  (cons value result)))
            lis
            values))

    (define (lset-union equal . lists)
      "Return the union of LISTS under EQUAL."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Set lists to combine.")))
        (returns (type list)
         (description "Set list containing elements from every input."))
        (effects procedure-call allocation error))
      (check-procedure 'lset-union equal)
      (let loop ((rest lists) (result '()))
        (cond
         ((null? rest) result)
         ((null-list? (car rest)) (loop (cdr rest) result))
         ((null? result) (loop (cdr rest) (car rest)))
         (else
          (loop
           (cdr rest)
           (fold (lambda (value acc)
                   (if (member value acc equal) acc (cons value acc)))
                 result
                 (car rest)))))))

    (define (lset-intersection equal lis1 . lists)
      "Return the intersection of LIS1 and LISTS under EQUAL."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis1 (type list)
          (description "First set list."))
         (lists (type list)
          (description "Additional set lists.")))
        (returns (type list)
         (description "Elements of LIS1 present in every additional list."))
        (effects procedure-call allocation error))
      (check-procedure 'lset-intersection equal)
      (if (null? lists)
          lis1
          (filter (lambda (value)
                    (every (lambda (lis) (member value lis equal)) lists))
                  lis1)))

    (define (lset-difference equal lis1 . lists)
      "Return LIS1 elements that are absent from LISTS under EQUAL."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis1 (type list)
          (description "Set list to subtract from."))
         (lists (type list)
          (description "Set lists whose elements are removed.")))
        (returns (type list)
         (description "Elements of LIS1 absent from every additional list."))
        (effects procedure-call allocation error))
      (check-procedure 'lset-difference equal)
      (if (null? lists)
          lis1
          (filter (lambda (value)
                    (not (any (lambda (lis) (member value lis equal))
                              lists)))
                  lis1)))

    (define (lset-xor equal . lists)
      "Return the symmetric difference of LISTS under EQUAL."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Set lists to combine by symmetric difference.")))
        (returns (type list)
         (description "Elements present in an odd set difference position."))
        (effects procedure-call allocation error))
      (check-procedure 'lset-xor equal)
      (let loop ((rest lists) (result '()))
        (if (null? rest)
            result
            (loop (cdr rest)
                  (append (lset-difference equal (car rest) result)
                          (lset-difference equal result (car rest)))))))

    (define (lset-diff+intersection equal lis1 . lists)
      "Return LIS1's difference and intersection with LISTS."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis1 (type list)
          (description "Set list to compare."))
         (lists (type list)
          (description "Additional set lists.")))
        (returns (type (values list list))
         (description "Two values: difference and intersection."))
        (effects procedure-call allocation error))
      (values (apply lset-difference equal lis1 lists)
              (apply lset-intersection equal lis1 lists)))

    (define (lset-union! equal . lists)
      "Destructively compute the union of LISTS when practical."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Set lists to combine.")))
        (returns (type list)
         (description "Set list containing elements from every input."))
        (effects procedure-call allocation error))
      (apply lset-union equal lists))

    (define (lset-intersection! equal lis1 . lists)
      "Destructively compute the intersection when practical."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis1 (type list)
          (description "First set list."))
         (lists (type list)
          (description "Additional set lists.")))
        (returns (type list)
         (description "Elements of LIS1 present in every additional list."))
        (effects procedure-call allocation error))
      (apply lset-intersection equal lis1 lists))

    (define (lset-difference! equal lis1 . lists)
      "Destructively compute the difference when practical."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis1 (type list)
          (description "Set list to subtract from."))
         (lists (type list)
          (description "Set lists whose elements are removed.")))
        (returns (type list)
         (description "Elements of LIS1 absent from every additional list."))
        (effects procedure-call allocation error))
      (apply lset-difference equal lis1 lists))

    (define (lset-xor! equal . lists)
      "Destructively compute the symmetric difference when practical."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lists (type list)
          (description "Set lists to combine by symmetric difference.")))
        (returns (type list)
         (description "Elements present in an odd set difference position."))
        (effects procedure-call allocation error))
      (apply lset-xor equal lists))

    (define (lset-diff+intersection! equal lis1 . lists)
      "Destructively compute difference and intersection when practical."
      #((parameters
         (equal (type procedure)
          (description "Two-argument element equivalence predicate."))
         (lis1 (type list)
          (description "Set list to compare."))
         (lists (type list)
          (description "Additional set lists.")))
        (returns (type (values list list))
         (description "Two values: difference and intersection."))
        (effects procedure-call allocation error))
      (apply lset-diff+intersection equal lis1 lists))))
