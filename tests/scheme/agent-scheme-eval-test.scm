;;; Portable evaluator test runner for the Agent Scheme R7RS library.
;;;
;;; This program runs under an external R7RS Scheme and exercises the portable
;;; evaluator library without loading the Emacs host adapter.

(import (scheme base)
        (scheme file)
        (scheme write)
        (agent-scheme eval)
        (only (agent-scheme runtime)
              audit-process-capability-result!
              audit-network-capability-result!
              authorize-process-capability
              authorize-network-capability
              context-audit-events
              network-capability-handle
              network-port-capability-handle
              new-eval-context
              process-capability-handle
              process-port-capability-handle))

;; Shared evaluator behavior runs through agent-scheme-fixture-test.scm. This
;; file keeps portable evaluator API and bootstrap invariants close to the R7RS
;; library.

(define failures 0)

;; Record one failed portable evaluator check and keep running the rest of the
;; suite so failures report together.
(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

;; Compare ACTUAL and EXPECTED using R7RS equal? and record a named failure.
(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

;; Evaluate SOURCE and compare the stable external value representation.
(define (check-external name source expected)
  (check name
         (agent-scheme-value->external (agent-scheme-eval-source source))
         expected))

;; Evaluate SOURCE with OPTIONS and compare the stable external value.
(define (check-external/options name source options expected)
  (check name
         (agent-scheme-value->external
          (agent-scheme-eval-source source #f options))
         expected))

;; Evaluate SOURCE as an evaluation-result datum and compare its external form.
(define (check-result-external name source expected)
  (check name
         (agent-scheme-result->external
          (agent-scheme-eval-source-result source))
         expected))

;; Report whether TEXT starts with PREFIX.
(define (string-prefix? prefix text)
  (let ((prefix-length (string-length prefix))
        (text-length (string-length text)))
    (and (<= prefix-length text-length)
         (let loop ((index 0))
           (or (= index prefix-length)
               (and (char=? (string-ref prefix index)
                            (string-ref text index))
                    (loop (+ index 1))))))))

;; Report whether TEXT contains NEEDLE.
(define (string-contains? text needle)
  (let ((text-length (string-length text))
        (needle-length (string-length needle)))
    (let loop ((index 0))
      (and (<= (+ index needle-length) text-length)
           (or (string-prefix? needle (substring text index text-length))
               (loop (+ index 1)))))))

;; Evaluate SOURCE as a result datum and require each substring.
(define (check-result-contains name source needles)
  (let ((actual
         (agent-scheme-result->external
          (agent-scheme-eval-source-result source))))
    (let loop ((rest needles))
      (if (not (null? rest))
          (begin
            (if (not (string-contains? actual (car rest)))
                (record-failure name (car rest) actual))
            (loop (cdr rest)))))))

;; Replace PATH with CONTENTS using the host Scheme runtime.
(define (write-host-test-file path contents)
  (if (file-exists? path)
      (delete-file path))
  (call-with-output-file path
    (lambda (port)
      (display contents port))))

;; Replace PATH with binary BYTES using the host Scheme runtime.
(define (write-host-binary-file path bytes)
  (if (file-exists? path)
      (delete-file path))
  (let ((port (open-binary-output-file path)))
    (for-each (lambda (byte) (write-u8 byte port)) bytes)
    (close-port port)))

;; Return PATH contents as a list of byte values using the host runtime.
(define (read-host-binary-file path)
  (let ((port (open-binary-input-file path)))
    (let loop ((bytes '()))
      (let ((byte (read-u8 port)))
        (if (eof-object? byte)
            (begin
              (close-port port)
              (reverse bytes))
            (loop (cons byte bytes)))))))

;; Return FIELD from a Scheme-readable result or audit datum.
(define (field-value datum field)
  (let ((entry (assq field (cdr datum))))
    (if entry (cadr entry) #f)))

;; Return the first audit/event datum whose event field is EVENT.
(define (find-event events event)
  (cond
   ((null? events) #f)
   ((equal? (field-value (car events) 'event) event) (car events))
   (else (find-event (cdr events) event))))

;; Return the first audit/event datum whose event and field match.
(define (find-event-with-field events event field value)
  (cond
   ((null? events) #f)
   ((and (equal? (field-value (car events) 'event) event)
         (equal? (field-value (car events) field) value))
    (car events))
   (else (find-event-with-field (cdr events) event field value))))

;; Find the primitive binding metadata record named NAME in SPECS.
(define (find-primitive-spec name specs)
  (cond
   ((null? specs) #f)
   ((eq? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-primitive-spec name (cdr specs)))))

;; Find manifest metadata by LIBRARY and NAME in SPECS.
(define (find-manifest-spec library name specs)
  (cond
   ((null? specs) #f)
   ((and (equal? (cadr (assq 'library (car specs))) library)
         (eq? (cadr (assq 'name (car specs))) name))
    (car specs))
   (else (find-manifest-spec library name (cdr specs)))))

;; Find the source-backed standard library metadata record named NAME in SPECS.
(define (find-source-library-spec name specs)
  (cond
   ((null? specs) #f)
   ((equal? (cadr (assq 'name (car specs))) name) (car specs))
   (else (find-source-library-spec name (cdr specs)))))

;; Return #t when THUNK raises any portable Scheme condition.
(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(check-external 'literal-number "42" "42")
(check 'literal-number-is-agent-owned
       (number? (agent-scheme-eval-source "42"))
       #f)
(check-external 'literal-string "\"ok\"" "\"ok\"")
(check-external 'quote-symbol "'alpha" "alpha")
(check-external 'quote-list "'(1 2 3)" "(1 2 3)")
(check 'empty-list-expression-error
       (raises? (lambda () (agent-scheme-eval-source "()")))
       #t)

(check-external 'definition-and-reference
                "(define answer 40)
                 (+ answer 2)"
                "42")
(check-external 'top-level-begin
                "(begin
                   (define answer 42)
                   answer)"
                "42")
(check-external 'operator-expression
                "((if #f + *) 3 4)"
                "12")
(check 'unknown-identifier
       (raises? (lambda () (agent-scheme-eval-source "missing")))
       #t)

(let ((names (agent-scheme-base-primitive-names))
      (prelude-names (agent-scheme-base-prelude-binding-names))
      (specs (agent-scheme-base-primitive-specs))
      (binding-specs (agent-scheme-base-binding-specs)))
  (check 'base-registry-names
         (if (and (memq '+ names)
                  (memq 'apply names)
                  (memq 'car names)
                  (memq 'vector-ref names)
                  (not (memq 'append names))
                  (not (memq 'cadr names))
                  (not (memq 'length names))
                  (not (memq 'map names))
                  (not (memq 'string-map names))
                  (not (memq 'string-for-each names))
                  (not (memq 'vector-map names))
                  (not (memq 'vector-for-each names))
                  (not (memq 'zero? names))
                  (memq 'append prelude-names)
                  (memq 'cadr prelude-names)
                  (memq 'length prelude-names)
                  (memq 'map prelude-names)
                  (memq 'string-map prelude-names)
                  (memq 'string-for-each prelude-names)
                  (memq 'vector-map prelude-names)
                  (memq 'vector-for-each prelude-names)
                  (memq 'zero? prelude-names)
                  (memq 'call-with-values names)
                  (memq 'call/cc names)
                  (memq 'dynamic-wind names)
                  (memq 'features names)
                  (memq 'make-parameter names)
                  (memq 'string->utf8 names)
                  (memq 'utf8->string names)
                  (memq 'values names))
             #t
             #f)
         #t)
  (check 'base-registry-specs
         (cadr (assq 'minimum-arity
                     (find-primitive-spec 'vector-ref specs)))
         2)
  (check 'base-kernel-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'vector-ref binding-specs)))
         'kernel)
  (check 'base-prelude-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'append binding-specs)))
         'prelude)
  (check 'base-prelude-string-map-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'string-map binding-specs)))
         'prelude)
  (check 'base-prelude-vector-for-each-source-spec
         (cadr (assq 'source
                     (find-primitive-spec 'vector-for-each binding-specs)))
         'prelude))

(let* ((manifest-specs (agent-scheme-primitive-manifest-binding-specs))
       (vector-ref
        (find-manifest-spec '(scheme base) 'vector-ref manifest-specs))
       (vector-set
        (find-manifest-spec '(scheme base) 'vector-set! manifest-specs))
       (delete-file
        (find-manifest-spec '(scheme file) 'delete-file manifest-specs))
       (open-input-file
        (find-manifest-spec '(scheme file) 'open-input-file manifest-specs))
       (current-second
        (find-manifest-spec '(scheme time) 'current-second manifest-specs)))
  (check 'primitive-manifest-vector-ref
         (and vector-ref
              (cadr (assq 'minimum-arity vector-ref))
              (cadr (assq 'maximum-arity vector-ref))
              (cadr (assq 'source vector-ref))
              (cadr (assq 'effect vector-ref))
              (eq? (cadr (assq 'backend-effect-path vector-ref))
                   'direct-runtime)
              (cadr (assq 'policy vector-ref))
              (memq 'vector (cadr (assq 'test-categories vector-ref)))
              #t)
         #t)
  (check 'primitive-manifest-vector-set-effect
         (and vector-set
              (list (cadr (assq 'effect vector-set))
                    (cadr (assq 'backend-effect-path vector-set))))
         '(mutation runtime-mutation))
  (check 'primitive-manifest-file-effect
         (and delete-file
              (list (cadr (assq 'source delete-file))
                    (cadr (assq 'effect delete-file))
                    (cadr (assq 'required-capability delete-file))
                    (cadr (assq 'backend-effect-path delete-file))
                    (cadr (assq 'policy-category delete-file))
                    (cadr (assq 'policy delete-file))))
         '(host-capability host-file file-system
           shared-capability-request standard-host-effect deny))
  (check 'primitive-manifest-file-stub-effect
         (and open-input-file
              (list (cadr (assq 'minimum-arity open-input-file))
                    (cadr (assq 'effect open-input-file))
                    (cadr (assq 'backend-effect-path open-input-file))
                    (cadr (assq 'policy open-input-file))))
         '(1 host-file shared-capability-request deny))
  (check 'primitive-manifest-time-effect
         (and current-second
              (list (cadr (assq 'effect current-second))
                    (cadr (assq 'required-capability current-second))
                    (cadr (assq 'backend-effect-path current-second))
                    (cadr (assq 'policy-category current-second))
                    (cadr (assq 'policy current-second))))
         '(host-time clock shared-capability-request
           standard-host-effect grant))
  (let ((read-char
         (find-manifest-spec '(scheme base) 'read-char manifest-specs)))
    (check 'primitive-manifest-port-runtime-path
           (and read-char
                (list (cadr (assq 'effect read-char))
                      (cadr (assq 'backend-effect-path read-char))))
           '(port-io runtime-port-check)))
  (let loop ((rest (agent-scheme-base-primitive-specs)))
    (if (not (null? rest))
        (let* ((spec (car rest))
               (manifest-spec
                (find-manifest-spec
                 '(scheme base)
                 (cadr (assq 'name spec))
                 manifest-specs)))
          (check 'primitive-manifest-base-alignment
                 (and manifest-spec
                      (equal? (cadr (assq 'minimum-arity manifest-spec))
                              (cadr (assq 'minimum-arity spec)))
                      (equal? (cadr (assq 'maximum-arity manifest-spec))
                              (cadr (assq 'maximum-arity spec)))
                      (eq? (cadr (assq 'source manifest-spec))
                           (cadr (assq 'source spec)))
                      (eq? (cadr (assq 'effect manifest-spec))
                           (cadr (assq 'effect spec))))
                 #t)
          (loop (cdr rest))))))

(let* ((source-specs (agent-scheme-standard-source-library-specs))
       (case-lambda-spec
        (find-source-library-spec '(scheme case-lambda) source-specs))
       (lazy-spec
        (find-source-library-spec '(scheme lazy) source-specs)))
  (check 'standard-source-library-case-lambda-exports
         (and case-lambda-spec
              (cadr (assq 'exports case-lambda-spec)))
         '(case-lambda))
  (check 'standard-source-library-lazy-exports
         (and lazy-spec
              (cadr (assq 'exports lazy-spec)))
         '(delay delay-force force make-promise promise?))
  (check 'standard-source-library-files
         (and case-lambda-spec
              lazy-spec
              (string? (cadr (assq 'source-file case-lambda-spec)))
              (string? (cadr (assq 'source-file lazy-spec))))
         #t)
  (check 'standard-source-library-case-lambda-file
         (and case-lambda-spec
              (cadr (assq 'source-file case-lambda-spec)))
         "scheme/standard-library/case-lambda.sld")
  (check 'standard-source-library-lazy-file
         (and lazy-spec
              (cadr (assq 'source-file lazy-spec)))
         "scheme/standard-library/lazy.sld"))

(check-external 'base-list-helpers
                "(list (length (append '(1 2) '(3 4)))
                       (cadr '(alpha beta gamma))
                       (equal? '(1 \"x\") '(1 \"x\")))"
                "(4 beta #t)")

(check-external 'records-construct-predicate-access-and-mutate
                "(define-record-type <pare>
                   (kons x y)
                   pare?
                   (x kar set-kar!)
                   (y kdr))
                 (let ((p (kons 1 2)))
                   (set-kar! p 3)
                   (list (pare? p)
                         (pare? (cons 1 2))
                         (kar p)
                         (kdr p)))"
                "(#t #f 3 2)")

(check-external 'circular-equality-terminates
                "(let ((left '#1=(a b . #1#))
                       (right '#2=(a b a b . #2#)))
                   (list (eq? left (cddr left))
                         (equal? left right)))"
                "(#t #t)")

(check-external 'base-scalar-helpers
                "(list (/ 5 2)
                       (abs -4)
                       (modulo -13 4)
                       (square 5)
                       (boolean=? #t (not #f))
                       (string->symbol (symbol->string 'agent-scheme)))"
                "(5/2 4 3 25 #t agent-scheme)")

(check-external 'numeric-tower-exact-rationals
                "(list (/ 3 4 5)
                       (+ 1/2 1/3)
                       (numerator (/ 6 4))
                       (denominator (/ 6 4))
                       (number->string 42 16)
                       (string->number \"2a\" 16))"
                "(3/20 5/6 3 2 \"2a\" 42)")

(check-external 'numeric-tower-polar-special-values
                "(import (scheme complex))
                 (list (make-polar +inf.0 0)
                       (make-polar 1 +inf.0)
                       (make-polar +nan.0 0))"
                "(+inf.0+nan.0i +nan.0+nan.0i +nan.0+nan.0i)")

(check-external 'base-vector-and-bytevector-helpers
                "(define v (vector 'a 'b 'c))
                 (vector-set! v 1 'changed)
                 (define b (bytevector 1 2 3))
                 (bytevector-u8-set! b 1 9)
                 (list v b)"
                "(#(a changed c) #u8(1 9 3))")

(check-external 'base-derived-string-vector-iteration
                "(let ((chars '())
                       (indexes (make-list 3)))
                   (string-for-each
                    (lambda (c) (set! chars (cons c chars)))
                    \"abc\")
                   (vector-for-each
                    (lambda (index)
                      (list-set! indexes index (* index index)))
                    '#(0 1 2))
                   (list
                    (string-map
                     (lambda (c) c)
                     \"HAL\")
                    chars
                    (vector-map + '#(1 2 3) '#(4 5 6 7))
                    indexes))"
                "(\"HAL\" (#\\c #\\b #\\a) #(5 7 9) (0 1 4))")

(check-external 'base-higher-order-helpers
                "(define total 0)
                 (for-each (lambda (x) (set! total (+ total x))) '(1 2 3))
                 (list (apply + 1 '(2 3 4))
                       (map (lambda (x) (* x x)) '(2 3 4))
                       total)"
                "(10 (4 9 16) 6)")

(check-external 'sequence-length-primitives-return-agent-numbers
                "(list
                   (string-length \"abc\")
                   (vector-length '#(a b c d))
                   (bytevector-length #u8(1 2 3 4 5)))"
                "(3 4 5)")

(check-result-external 'multiple-values-result
                       "(values 1 2)"
                       "(evaluation-result (status values) (values (1 2)) (events ()) (budget (steps-used 5) (host-calls 1)))")

(check-result-contains 'debugger-unbound-variable-result
                       "missing"
                       '("(status error)"
                         "(condition (type unbound-variable)"
                         "(symbol missing)"
                         "(phase evaluation)"
                         "(stack ((frame (id f-0)"
                         "(environment ((frame f-0)"
                         "(restarts ((restart (id abort)"))

(check-result-contains 'debugger-current-error-restarts
                       "(import (scheme base) (agent debugger))
                        (with-exception-handler
                         (lambda (condition)
                           (condition-restarts (current-error)))
                         (lambda ()
                           (raise-continuable 'boom)))"
                       '("(status ok)"
                         "(restart (id abort)"
                         "(restart (id continue-with-warning)"))

(check-result-contains 'debugger-yield-event
                       "(import (scheme base) (agent debugger))
                        (debugger-yield
                         '(condition
                           (type synthetic)
                           (message \"example\")))
                        'done"
                       '("(status ok)"
                         "(value done)"
                         "(events ((debugger (condition (type synthetic) (message \"example\")))))"))

(check-external 'multiple-values-binding-forms
                "(let ((a 'a) (b 'b) (x 'x) (y 'y))
                   (let*-values (((a b) (values x y))
                                 ((x y) (values a b)))
                     (list a b x y)))"
                "(x y x y)")

(check-external 'call-with-values-consumer
                "(call-with-values (lambda () (values 4 5))
                                   (lambda (a b) (- b a)))"
                "1")

(check-external 'define-values-top-level
                "(define-values (root remainder)
                   (exact-integer-sqrt 10))
                 (define-values (head . tail)
                   (values 'a 'b 'c))
                 (define-values all
                   (values 1 2 3))
                 (list root remainder head tail all)"
                "(3 1 a (b c) (1 2 3))")

(check-external 'define-values-internal
                "((lambda ()
                    (define-values (left right)
                      (values 'l 'r))
                    (list left right)))"
                "(l r)")

(check-external 'base-features-parameters-and-utf8
                "(let ((available (features))
                       (setting (make-parameter 'outer)))
                   (let ((bytes (string->utf8 \"agent\")))
                     (list (pair? (memq 'r7rs available))
                           (pair? (memq 'agent-scheme available))
                           (setting)
                           (parameterize ((setting 'inner))
                             (setting))
                           (setting)
                           bytes
                           (utf8->string bytes)
                           (utf8->string bytes 1 4))))"
                "(#t #t outer inner outer #u8(97 103 101 110 116) \"agent\" \"gen\")")

(check-external 'call/cc-escape
                "(call/cc (lambda (escape) (+ 1 (escape 42))))"
                "42")

(check-external 'dynamic-wind-exit
                "(let ((path '()))
                   (define (add tag) (set! path (cons tag path)))
                   (call/cc
                    (lambda (escape)
                      (dynamic-wind
                       (lambda () (add 'before))
                       (lambda ()
                         (add 'during)
                         (escape 'done))
                       (lambda () (add 'after)))))
                   (reverse path))"
                "(before during after)")

(check-external 'call/cc-reenter-after-return
                "(let ((again #f))
                   (let ((value (call/cc
                                 (lambda (k)
                                   (set! again k)
                                   'first))))
                     (if (eq? value 'first)
                         (again 'second)
                         value)))"
                "second")

(check-external 'call/cc-repeated-invocation
                "(let ((again #f)
                       (seen '()))
                   (let ((value (call/cc
                                 (lambda (k)
                                   (set! again k)
                                   'start))))
                     (set! seen (cons value seen))
                     (if (< (length seen) 3)
                         (again (length seen))
                         (reverse seen))))"
                "(start 1 2)")

(check-external 'dynamic-wind-reentry
                "(let ((again #f)
                       (outside #f)
                       (path '()))
                   (define (add tag) (set! path (cons tag path)))
                   (call/cc
                    (lambda (escape)
                      (set! outside escape)
                      (dynamic-wind
                       (lambda () (add 'before-outer))
                       (lambda ()
                         (dynamic-wind
                          (lambda () (add 'before-inner))
                          (lambda ()
                            (call/cc
                             (lambda (k)
                               (set! again k)
                               'captured))
                            (add 'during-inner)
                            (outside 'escaped))
                          (lambda () (add 'after-inner))))
                       (lambda () (add 'after-outer)))))
                   (if again
                       (let ((resume again))
                         (set! again #f)
                         (resume 'resumed))
                       (reverse path)))"
                "(before-outer before-inner during-inner after-inner after-outer before-outer before-inner during-inner after-inner after-outer)")

(check-external 'call/cc-multiple-values
                "(let ((again #f))
                   (call-with-values
                    (lambda ()
                      (call/cc
                       (lambda (k)
                         (set! again k)
                         (values 1 2))))
                    (lambda (a b)
                      (if (= a 1)
                          (again 3 4)
                          (list a b)))))"
                "(3 4)")

(check-external 'let-values-continuation-multiple-values
                "(let ((again #f))
                   (let-values (((a b)
                                 (call/cc
                                  (lambda (k)
                                    (set! again k)
                                    (values 1 2)))))
                     (if (= a 1)
                         (again 3 4)
                         (list a b))))"
                "(3 4)")

(check-external 'let*-values-continuation-multiple-values
                "(let ((again #f))
                   (let*-values (((a b)
                                  (call/cc
                                   (lambda (k)
                                     (set! again k)
                                     (values 1 2))))
                                 ((c) (+ a b)))
                     (if (= a 1)
                         (again 3 4)
                         (list a b c))))"
                "(3 4 7)")

(check-external 'guard-raise
                "(guard (exn (else (list 'caught exn)))
                   (raise 'boom))"
                "(caught boom)")

(check-external 'raise-continuable
                "(with-exception-handler
                   (lambda (exn) 42)
                   (lambda ()
                     (+ (raise-continuable 'warning) 23)))"
                "65")

(check-external 'error-object
                "(guard (exn
                         ((error-object? exn)
                          (list (error-object-message exn)
                                (error-object-irritants exn))))
                   (error \"bad input\" 'alpha 7))"
                "(\"bad input\" (alpha 7))")

(check-external 'define-syntax-expands-ellipsis
                "(define x 0)
                 (define-syntax unless
                   (syntax-rules ()
                     ((unless test body ...)
                      (if test #f (begin body ...)))))
                 (unless #f
                   (set! x 41)
                   (+ x 1))"
                "42")

(check-external 'introduced-bindings-are-hygienic
                "(define-syntax my-or
                   (syntax-rules ()
                     ((my-or) #f)
                     ((my-or expr) expr)
                     ((my-or expr next ...)
                      (let ((temp expr))
                        (if temp temp (my-or next ...))))))
                 (let ((temp 99))
                   (my-or #f temp))"
                "99")

(check-external 'let-syntax-is-referentially-transparent
                "(let ((x 'outer))
                   (let-syntax ((m (syntax-rules ()
                                     ((m) x))))
                     (let ((x 'inner))
                       (m))))"
                "outer")

(check 'free-template-identifiers-do-not-capture-use-site
       (raises? (lambda ()
                  (agent-scheme-eval-source
                   "(define-syntax expose-x
                      (syntax-rules ()
                        ((expose-x) x)))
                    (let ((x 1))
                      (expose-x))")))
       #t)

(check-external 'letrec-syntax-allows-recursive-transformers
                "(letrec-syntax
                     ((my-or
                       (syntax-rules ()
                         ((my-or) #f)
                         ((my-or expr) expr)
                         ((my-or expr next ...)
                          (let ((temp expr))
                            (if temp temp (my-or next ...)))))))
                   (my-or #f #f 7))"
                "7")

(check-external 'named-let-expands-through-letrec
                "(let loop ((n 5) (acc 0))
                   (if (= n 0)
                       acc
                       (loop (- n 1) (+ acc 1))))"
                "5")

(check-external 'cond-arrow-respects-literal-binding
                "(list
                   (cond ((assv 'b '((a 1) (b 2))) => cadr)
                         (else #f))
                   (let ((=> #f))
                     (cond (#t => 'ok))))"
                "(2 ok)")

(check-external 'case-expands-from-base-syntax
                "(list
                   (case (car '(c d))
                     ((a e i o u) 'vowel)
                     ((c d) 'consonant)
                     (else 'other))
                   (case 'b
                     ((a) 'a)
                     ((b c) => (lambda (x) (list x 'hit)))
                     (else #f)))"
                "(consonant (b hit))")

(check-external 'do-expands-nested-ellipses
                "(do ((i 0 (+ i 1))
                      (acc 0 (+ acc i)))
                     ((= i 5) acc))"
                "10")

(check-external 'dotted-patterns-and-templates
                "(define-syntax rest-list
                   (syntax-rules ()
                     ((rest-list first . rest)
                      'rest)))
                 (define-syntax make-pair
                   (syntax-rules ()
                     ((make-pair left right)
                      '(left . right))))
                 (list (rest-list a b c)
                       (make-pair alpha beta))"
                "((b c) (alpha . beta))")

(check-external 'nested-ellipsis-template-expands
                "(define-syntax echo-groups
                   (syntax-rules ()
                     ((echo-groups ((head item ...) ...))
                      '((head item ...) ...))))
                 (echo-groups ((a 1 2) (b 3) (c)))"
                "((a 1 2) (b 3) (c))")

(check-external 'quasiquote-evaluates-unquotes
                "(list
                   (quasiquote (a (unquote (+ 1 2))
                                  (unquote-splicing (list 'b 'c))))
                   (quasiquote #(1 (unquote (+ 1 2))))
                   (quasiquote (outer
                                 (quasiquote
                                  (inner (unquote (+ 1 2))))
                                 (unquote (+ 2 3)))))"
                "((a 3 b c) #(1 3) (outer (quasiquote (inner (unquote (+ 1 2)))) 5))")

(check-external 'cond-expand-selects-base-feature
                "(list
                   (cond-expand (r7rs 'ok) (else 'missing))
                   (cond-expand
                    ((library (scheme base)) 'base)
                    (else 'missing)))"
                "(ok base)")

(check 'import-scheme-base-into-empty-environment
       (agent-scheme-value->external
        (agent-scheme-eval-source
         "(import (scheme base))
          (+ 1 2)"
         (agent-scheme-make-empty-environment)))
       "3")

(check-external 'define-library-import-export
                "(define-library (agent-scheme fixture math)
                   (export answer)
                   (import (scheme base))
                   (begin
                     (define answer 42)))
                 (import (agent-scheme fixture math))
                 answer"
                "42")

(check-external 'library-import-set-modifiers
                "(define-library (agent-scheme fixture modifiers)
                   (export add sub hidden)
                   (import (scheme base))
                   (begin
                     (define (add x y) (+ x y))
                     (define (sub x y) (- x y))
                     (define hidden 99)))
                 (import (only (agent-scheme fixture modifiers) add)
                         (except
                          (prefix (agent-scheme fixture modifiers) lib-)
                          lib-hidden)
                         (rename
                          (agent-scheme fixture modifiers)
                          (sub minus)))
                 (list (add 1 2)
                       (lib-add 3 4)
                       (lib-sub 10 6)
                       (minus 8 5))"
                "(3 7 4 3)")

(check-external 'library-export-rename
                "(define-library (agent-scheme fixture export-rename)
                   (export (rename internal external))
                   (import (scheme base))
                   (begin
                     (define internal 42)))
                 (import (agent-scheme fixture export-rename))
                 external"
                "42")

(check-external 'emacs-capability-import-empty
                "(import (emacs buffer)
                         (emacs diff)
                         (emacs frame)
                         (emacs process))
                 'ok"
                "ok")

(check 'conflicting-library-imports
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(define-library (agent-scheme fixture left)
              (export value)
              (import (scheme base))
              (begin (define value 'left)))
            (define-library (agent-scheme fixture right)
              (export value)
              (import (scheme base))
              (begin (define value 'right)))
            (import (agent-scheme fixture left)
                    (agent-scheme fixture right))
            value")))
       #t)

(check-external 'exported-library-macro-keeps-scope
                "(define-library (agent-scheme fixture syntax)
                   (export choose)
                   (import (scheme base))
                   (begin
                     (define default 'library)
                     (define-syntax choose
                       (syntax-rules ()
                         ((choose) default)))))
                 (import (scheme base)
                         (agent-scheme fixture syntax))
                 (let ((default 'program))
                   (choose))"
                "library")

(check-external 'library-cond-expand-declaration
                "(define-library (agent-scheme fixture conditional)
                   (cond-expand
                     ((library (scheme base))
                      (export answer)
                      (import (scheme base))
                      (begin (define answer 42)))
                     (else
                      (export answer)
                      (begin (define answer 'missing)))))
                 (import (agent-scheme fixture conditional))
                 answer"
                "42")

(check 'include-declarations-are-policy-gated
       (raises?
       (lambda ()
         (agent-scheme-eval-source
          "(define-library (agent-scheme fixture include)
             (export answer)
             (import (scheme base))
             (include \"fixtures/r7rs/conformance-cases.scm\"))")))
       #t)

;; Include policy options grant this portable test runner access to fixture
;; files while preserving the evaluator's default-deny host policy cases.
(define include-policy-options
  '((include-directory . ".")
    (include-paths . ("fixtures/r7rs"))
    (file-paths . ("fixtures/r7rs"))))

;; First-class file grants are the portable capability vocabulary for the same
;; fixture reads that legacy path allow-lists covered while bootstrapping.
(define file-grant-options
  '((include-directory . ".")
    (capability-grants
     (capability-grant
      (id portable-file-grant)
      (domain file)
      (operations metadata read include include-ci load library-source)
      (scope (project-root ".")
             (paths ("fixtures/r7rs"))
             (remote denied)
             (symlinks resolve-within-root))
      (expires never)))))

;; Host-side temporary file path used for portable delete-file coverage.
(define delete-test-path "/tmp/agent-scheme-delete-capability.scm")

;; Host-side temporary paths used for portable file port capability coverage.
(define port-test-input-path "/tmp/agent-scheme-port-input.scm")
;; Host-side temporary file path used for portable open-output-file coverage.
(define port-test-output-path "/tmp/agent-scheme-port-output.scm")
;; Host-side temporary file path used for portable call-with-output-file coverage.
(define port-test-call-output-path "/tmp/agent-scheme-port-call-output.scm")
;; Host-side temporary file path used for portable with-output-to-file coverage.
(define port-test-with-output-path "/tmp/agent-scheme-port-with-output.scm")
;; Host-side temporary file path used for portable close-limit coverage.
(define port-test-close-output-path "/tmp/agent-scheme-port-close-output.scm")
;; Host-side temporary input file path used for portable binary port coverage.
(define port-test-binary-input-path "/tmp/agent-scheme-port-input.bin")
;; Host-side temporary output file path used for portable binary port coverage.
(define port-test-binary-output-path "/tmp/agent-scheme-port-output.bin")

;; First-class file grant that allows the portable evaluator to delete only
;; the host-side temporary file above, plus metadata checks after deletion.
(define delete-file-grant-options
  '((include-directory . "/tmp")
    (capability-grants
     (capability-grant
      (id portable-delete-grant)
      (domain file)
      (operations metadata delete)
      (scope (file-root "/tmp")
             (paths ("agent-scheme-delete-capability.scm"))
             (remote denied)
             (symlinks resolve-within-root))
      (expires never)))))

;; A session id marks portable evaluation as an authorized REPL-style
;; interaction context without exposing any host adapter state.
(define repl-session-options
  '((session-id . portable-repl)))

;; Session context alone is not enough when policy denies standard host effects.
(define repl-session-denied-options
  '((session-id . portable-repl-denied)
    (policy-actions
     (standard-host-effect . deny))))

;; Clock grants authorize policy-gated `(scheme time)` host observations.
(define clock-grant-options
  '((capability-grants
     (capability-grant
      (id portable-clock-grant)
      (domain clock)
      (operations read)
      (scope (clock system))
      (expires never)))))

;; First-class process grants are host-neutral request/decision vocabulary.
;; Host adapters decide whether to connect the authorization to a real child
;; process; the portable runtime owns the datum shape and grant matching.
(define process-grant-options
  '((policy-actions
     (command-process . allow)
     (emacs-read-only . allow))
    (capability-grants
     (capability-grant
      (id portable-process-grant)
      (domain process)
      (operations spawn observe output input terminate)
      (scope (command "portable-process")
             (working-directory "/tmp")
             (environment ("OPENAI_API_KEY")))
      (expires never)))))

;; Process grant without policy allow action proves policy still gates spawns.
(define process-grant-without-policy-options
  '((capability-grants
     (capability-grant
      (id portable-process-grant)
      (domain process)
      (operations spawn)
      (scope (command "portable-process"))
      (expires never)))))

;; Process request resource with secrets exercises redaction in audit events.
(define portable-process-resource
  '((command "portable-process")
    (arguments ("--token=sk-portable-process1234567890"))
    (cwd "/tmp")
    (environment (("OPENAI_API_KEY" "sk-portable-env1234567890")))))

;; Process request resource that reaches policy without secret-bearing fields.
(define portable-process-policy-resource
  '((command "portable-process")
    (arguments ())
    (cwd "/tmp")))

;; Process request resource whose command intentionally misses grant scope.
(define portable-process-command-mismatch-resource
  '((command "other-process")
    (arguments ())
    (cwd "/tmp")))

;; First-class network grants are host-neutral request/decision vocabulary.
;; Host adapters decide whether to connect the authorization to real transport;
;; the portable runtime owns the datum shape, grant matching, and audit records.
(define network-grant-options
  '((policy-actions
     (network-access . allow))
    (capability-grants
     (capability-grant
      (id portable-network-grant)
      (domain network)
      (operations request stream)
      (scope (schemes ("https"))
             (hosts ("api.example.test"))
             (ports (443))
             (methods (GET POST))
             (header-classes (metadata))
             (payload-classes (public redacted))
             (max-response-bytes 64)
             (max-redirects 0)
             (max-timeout-ms 1000)
             (stream-lifetime-ms 5000))
      (expires never)))))

;; Network grant without policy allow action proves policy still gates egress.
(define network-grant-without-policy-options
  '((capability-grants
     (capability-grant
      (id portable-network-grant)
      (domain network)
      (operations request)
      (scope (schemes ("https"))
             (hosts ("api.example.test"))
             (ports (443))
             (methods (GET))
             (header-classes (metadata))
             (payload-classes (public))
             (max-response-bytes 64))
      (expires never)))))

;; Network request resource with secrets exercises redaction in audit events.
(define portable-network-resource
  '((url "https://api.example.test/v1")
    (scheme "https")
    (host "api.example.test")
    (port 443)
    (method POST)
    (headers (("X-Trace" "ok")))
    (header-classes (metadata))
    (payload "token sk-portable-network1234567890")
    (payload-class public)
    (response-size 64)
    (redirects 0)
    (timeout-ms 50)))

;; Network request resource whose host intentionally misses grant scope.
(define portable-network-host-mismatch-resource
  '((url "https://other.example.test/v1")
    (scheme "https")
    (host "other.example.test")
    (port 443)
    (method POST)
    (header-classes (metadata))
    (payload-class public)
    (response-size 64)
    (redirects 0)))

;; First-class file grants for host-backed file port reads and creations.
(define file-port-grant-options
  '((include-directory . "/tmp")
    (capability-grants
     (capability-grant
      (id portable-port-grant)
      (domain file)
      (operations read create)
      (scope (file-root "/tmp")
             (paths ("agent-scheme-port-input.scm"
                     "agent-scheme-port-output.scm"
                     "agent-scheme-port-call-output.scm"
                     "agent-scheme-port-with-output.scm"
                     "agent-scheme-port-input.bin"
                     "agent-scheme-port-output.bin"))
             (remote denied)
             (symlinks portable-unresolved))
      (expires never)))))

(check-external/options 'include-reads-policy-allowed-body
                        "(define-library (agent-scheme fixture include-body)
                           (export answer)
                           (import (scheme base))
                           (include \"fixtures/r7rs/include-body.scm\"))
                         (import (agent-scheme fixture include-body))
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'include-ci-folds-policy-allowed-body
                        "(define-library (agent-scheme fixture include-ci-body)
                           (export mixedanswer)
                           (import (scheme base))
                           (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
                         (import (agent-scheme fixture include-ci-body))
                         mixedanswer"
                        include-policy-options
                        "42")

(check-external/options 'include-library-declarations-splice
                        "(define-library
                           (agent-scheme fixture included-declarations)
                           (include-library-declarations
                            \"fixtures/r7rs/include-library-declarations.scm\"))
                         (import
                          (agent-scheme fixture included-declarations))
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'include-file-grant-allowed-body
                        "(define-library (agent-scheme fixture include-body)
                           (export answer)
                           (import (scheme base))
                           (include \"fixtures/r7rs/include-body.scm\"))
                         (import (agent-scheme fixture include-body))
                         answer"
                        file-grant-options
                        "42")

(check-external/options 'include-ci-file-grant-allowed-body
                        "(define-library (agent-scheme fixture include-ci-body)
                           (export mixedanswer)
                           (import (scheme base))
                           (include-ci \"fixtures/r7rs/include-ci-body.scm\"))
                         (import (agent-scheme fixture include-ci-body))
                         mixedanswer"
                        file-grant-options
                        "42")

(check-external 'standard-case-lambda-import
                "(import (scheme base) (scheme case-lambda))
                 ((case-lambda
                    ((x) x)
                    ((x y) (+ x y)))
                  1 2)"
                "3")

(check-external 'standard-case-lambda-rest-import
                "(import (scheme base) (scheme case-lambda))
                 (list
                  ((case-lambda
                     ((x) x)
                     ((x y . rest) (list x y rest)))
                   1 2 3 4)
                  ((case-lambda
                     (all all))
                   'a 'b))"
                "((1 2 (3 4)) (a b))")

(check-external 'standard-char-and-cxr-imports
                "(import (scheme base) (scheme char) (scheme cxr))
                 (list (char-upcase #\\a)
                       (char-downcase #\\Z)
                       (char-foldcase #\\A)
                       (char-alphabetic? #\\A)
                       (char-numeric? #\\9)
                       (char-whitespace? #\\space)
                       (digit-value #\\9)
                       (char-ci=? #\\A #\\a)
                       (string-upcase \"Az\")
                       (string-ci<? \"abc\" \"BCD\")
                       (cadddr '(a b c d e)))"
                "(#\\A #\\z #\\a #t #t #t 9 #t \"AZ\" #t d)")

(check-external 'standard-inexact-transcendentals
                "(import (scheme inexact))
                 (list (sqrt 9)
                       (sin 0)
                       (cos 0)
                       (tan 0)
                       (exp 0)
                       (log 1))"
                "(3.0 0.0 1.0 0.0 1.0 0.0)")

(check-external 'standard-lazy-import-memoizes
                "(import (scheme base) (scheme lazy))
                 (let ((count 0))
                   (let ((promise
                          (delay
                            (begin
                              (set! count (+ count 1))
                              count))))
                     (list (force promise)
                           (force promise)
                           count)))"
                "(1 1 1)")

(check-external 'standard-write-import-string-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (display \"ok\" out)
                   (get-output-string out))"
                "\"ok\"")

(check-external 'standard-write-shared-output
                "(import (scheme base) (scheme write))
                 (let ((x (list 'a)))
                   (let ((out (open-output-string)))
                     (write-shared (list x x) out)
                     (get-output-string out)))"
                "\"(#0=(a) #0#)\"")

(check-external 'standard-write-circular-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (write '#1=(a . #1#) out)
                   (get-output-string out))"
                "\"#0=(a . #0#)\"")

(check-external 'standard-write-simple-output
                "(import (scheme base) (scheme write))
                 (let ((out (open-output-string)))
                   (write-simple '#(1 \"x\") out)
                   (get-output-string out))"
                "\"#(1 \\\"x\\\")\"")

(check-external 'standard-write-record-output
                "(import (scheme base) (scheme write))
                 (define-record-type <pare>
                   (kons x y)
                   pare?
                   (x kar)
                   (y kdr))
                 (let ((out (open-output-string)))
                   (write (kons 1 2) out)
                   (get-output-string out))"
                "\"#<record <pare>>\"")

(check-external 'standard-string-ports-read-and-write
                "(import (scheme base) (scheme read) (scheme write))
                 (let ((in (open-input-string \"(alpha 1) \"))
                       (out (open-output-string)))
                   (write (read in) out)
                   (write-char (read-char in) out)
                   (list (get-output-string out)
                         (eof-object? (read in))))"
                "(\"(alpha 1) \" #t)")

(check-external 'standard-string-port-read-write-round-trip
                "(import (scheme base) (scheme read) (scheme write))
                 (let ((out (open-output-string)))
                   (write '(a \"b\" #u8(1 2)) out)
                   (read (open-input-string (get-output-string out))))"
                "(a \"b\" #u8(1 2))")

(check-external 'standard-bytevector-ports-read-and-write
                "(import (scheme base))
                 (let ((in (open-input-bytevector #u8(1 2 3)))
                       (out (open-output-bytevector)))
                   (write-u8 (read-u8 in) out)
                   (write-bytevector (read-bytevector 4 in) out)
                   (list (eof-object? (read-u8 in))
                         (get-output-bytevector out)))"
                "(#t #u8(1 2 3))")

(check-external 'standard-eval-import-evaluates-scheme
                "(import (scheme base) (scheme eval))
                 (eval '(* 7 3) (environment '(scheme base)))"
                "21")

(check 'standard-eval-immutable-environment-rejects-definition
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme eval))
            (eval '(define foo 32) (environment '(scheme base)))")))
       #t)

(check-external/options 'standard-repl-interaction-environment-mutates-session
                        "(import (scheme base) (scheme eval) (scheme repl))
                         (eval '(define portable-repl-value 42)
                               (interaction-environment))
                         portable-repl-value"
                        repl-session-options
                        "42")

(check 'standard-repl-interaction-environment-policy-denied
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme repl))
            (interaction-environment)"
           #f
           repl-session-denied-options)))
       #t)

(check 'standard-load-default-denied
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme load))
            (load \"fixtures/r7rs/include-body.scm\")")))
       #t)

(check-external/options 'standard-load-policy-allowed
                        "(import (scheme base) (scheme load))
                         (load \"fixtures/r7rs/include-body.scm\")
                         answer"
                        include-policy-options
                        "42")

(check-external/options 'standard-load-file-grant-allowed
                        "(import (scheme base) (scheme load))
                         (load \"fixtures/r7rs/include-body.scm\")
                         answer"
                        file-grant-options
                        "42")

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (scheme load))
          (load \"fixtures/r7rs/include-body.scm\")
          answer"
         #f
         file-grant-options))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'domain 'code-loading))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'code-loading))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'code-loading)))
  (check 'standard-load-audits-code-loading-request
         (and request
              decision
              audit
              (equal? (field-value request 'operation) 'load)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value audit 'result) '(ok evaluated))
              #t)
         #t))

(check 'standard-file-import-default-denied
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"fixtures/r7rs/conformance-cases.scm\")")))
       #t)

(let* ((result
       (agent-scheme-eval-source-result
         "(import (scheme base) (scheme file))
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"))
       (events (field-value result 'events))
       (event (find-event events 'policy-decision)))
  (check 'standard-file-default-denial-audits
         (and event
              (equal? (field-value event 'event) 'policy-decision)
              (equal? (field-value event 'category) 'standard-host-effect)
              (equal? (field-value event 'operation) "file-exists?")
              (equal? (field-value event 'decision) 'denied)
              (equal? (field-value event 'filename)
                      "fixtures/r7rs/conformance-cases.scm")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (scheme time))
          (current-second)"))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'domain 'clock))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'clock))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'clock)))
  (check 'standard-time-default-denial-audits-clock-request
         (and (equal? (field-value result 'status) 'error)
              request
              decision
              audit
              (equal? (field-value request 'operation) 'current-second)
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value audit 'result)
                      '(error "no active clock grant covers request"))
              #t)
         #t))

(check-external/options 'standard-time-clock-grant-allowed
                        "(import (scheme base) (scheme time))
                         (list (real? (current-second))
                               (exact-integer? (current-jiffy))
                               (exact-integer? (jiffies-per-second))
                               (> (jiffies-per-second) 0))"
                        clock-grant-options
                        "(#t #t #t #t)")

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (scheme time))
          (current-jiffy)"
         #f
         clock-grant-options))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'domain 'clock))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'clock))
       (policy (find-event-with-field
                events 'policy-decision 'domain 'clock))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'clock)))
  (check 'standard-time-clock-grant-audits-request-decision-result
         (and (equal? (field-value result 'status) 'ok)
              request
              decision
              policy
              audit
              (equal? (field-value request 'operation) 'current-jiffy)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-clock-grant)
              (equal? (field-value policy 'decision) 'allowed)
              (equal? (car (field-value audit 'result)) 'ok)
              #t)
         #t))

(check-external/options 'standard-file-import-policy-allowed
                        "(import (scheme base) (scheme file))
                         (file-exists?
                          \"fixtures/r7rs/conformance-cases.scm\")"
                        include-policy-options
                        "#t")

(check-external/options 'standard-file-import-file-grant-allowed
                        "(import (scheme base) (scheme file))
                         (file-exists?
                          \"fixtures/r7rs/conformance-cases.scm\")"
                        file-grant-options
                        "#t")

(write-host-test-file delete-test-path "(define old 1)")

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (scheme file))
          (delete-file \"agent-scheme-delete-capability.scm\")
          (file-exists? \"agent-scheme-delete-capability.scm\")"
         #f
         delete-file-grant-options))
       (events (field-value result 'events))
       (request (find-event-with-field
                 events 'capability-request 'operation 'delete))
       (decision (find-event-with-field
                  events 'capability-decision 'grant 'portable-delete-grant))
       (audit (find-event-with-field
               events 'capability-audit 'operation 'delete)))
  (check 'standard-delete-file-grant-allowed
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-value->external (field-value result 'value))
               "#f")
              (not (file-exists? delete-test-path))
              request
              decision
              audit
              (equal? (field-value request 'domain) 'file)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value audit 'result) '(ok deleted))
              #t)
         #t))

(let* ((context (new-eval-context process-grant-options))
       (authorization
        (authorize-process-capability
         '(portable process)
         "process-start!"
         context
         'spawn
         portable-process-resource
         '("portable-process")))
       (_audit
        (audit-process-capability-result!
         context
         authorization
         '(handle process-job h-portable-1)
         #f))
       (events (context-audit-events context))
       (request (find-event-with-field
                 events 'capability-request 'domain 'process))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'process))
       (policy (find-event-with-field
                events 'policy-decision 'category 'command-process))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'process))
       (external (agent-scheme-result->external (list 'events events))))
  (check 'portable-process-capability-authorizes-and-audits
         (and request
              decision
              policy
              audit
              (equal? (field-value request 'operation) 'spawn)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-process-grant)
              (equal? (field-value policy 'decision) 'allowed)
              (equal? (field-value audit 'result)
                      '(ok (handle process-job h-portable-1)))
              (not (string-contains? external "sk-portable-process"))
              (not (string-contains? external "sk-portable-env"))
              #t)
         #t))

(let* ((context (new-eval-context process-grant-without-policy-options))
       (raised
        (raises?
         (lambda ()
           (authorize-process-capability
            '(portable process)
            "process-start!"
            context
            'spawn
            portable-process-policy-resource
            '("portable-process")))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'process))
       (policy (find-event-with-field
                events 'policy-decision 'category 'command-process)))
  (check 'portable-process-capability-denies-without-policy
         (and raised
              decision
              policy
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value policy 'decision) 'denied)
              #t)
         #t))

(let* ((context (new-eval-context process-grant-options))
       (raised
        (raises?
         (lambda ()
           (authorize-process-capability
            '(portable process)
            "process-start!"
            context
            'spawn
            portable-process-command-mismatch-resource
            '("portable-process")))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'process)))
  (check 'portable-process-capability-denies-command-mismatch
         (and raised
              decision
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value decision 'grant) 'none)
              #t)
         #t))

(check 'portable-process-capability-handle-datums
       (list
        (process-capability-handle
         'h-portable-1
         '((command "portable-process") (arguments ("--safe")))
         'portable-process-grant
         'live)
        (process-port-capability-handle
         'p-portable-1
         'textual-input
         'h-portable-1
         '(read close)
         'portable-process-grant
         '()
         'open))
       '((handle
          (id h-portable-1)
          (kind process-job)
          (domain process)
          (command "portable-process")
          (arguments ("--safe"))
          (grant portable-process-grant)
          (status live))
         (port-capability
          (id p-portable-1)
          (kind textual-input)
          (backing process)
          (operations read close)
          (grant portable-process-grant)
          (limits)
          (path h-portable-1)
          (status open))))

(let* ((context (new-eval-context network-grant-options))
       (authorization
        (authorize-network-capability
         '(portable network)
         "network-http-request"
         context
         'request
         portable-network-resource))
       (_audit
        (audit-network-capability-result!
         context
         authorization
         '(network-response (status 200) (body "ok"))
         #f))
       (events (context-audit-events context))
       (request (find-event-with-field
                 events 'capability-request 'domain 'network))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'network))
       (policy (find-event-with-field
                events 'policy-decision 'category 'network-access))
       (audit (find-event-with-field
               events 'capability-audit 'domain 'network))
       (audit-result (and audit (field-value audit 'result)))
       (external (agent-scheme-result->external (list 'events events))))
  (check 'portable-network-capability-authorizes-and-audits
         (and request
              decision
              policy
              audit
              audit-result
              (equal? (field-value request 'operation) 'request)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-network-grant)
              (equal? (field-value policy 'decision) 'allowed)
              (equal? (car audit-result) 'ok)
              (equal? (field-value (cadr audit-result) 'body) "ok")
              (string-contains? external "(status 200)")
              (not (string-contains? external "sk-portable-network"))
              #t)
         #t))

(let* ((context (new-eval-context network-grant-without-policy-options))
       (raised
        (raises?
         (lambda ()
           (authorize-network-capability
            '(portable network)
            "network-http-request"
            context
            'request
            '((url "https://api.example.test/v1")
              (scheme "https")
              (host "api.example.test")
              (port 443)
              (method GET)
              (header-classes (metadata))
              (payload-class public)
              (response-size 64)
              (redirects 0))))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'network))
       (policy (find-event-with-field
                events 'policy-decision 'category 'network-access)))
  (check 'portable-network-capability-denies-without-policy
         (and raised
              decision
              policy
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value policy 'decision) 'denied)
              #t)
         #t))

(let* ((context (new-eval-context network-grant-options))
       (raised
        (raises?
         (lambda ()
           (authorize-network-capability
            '(portable network)
            "network-http-request"
            context
            'request
            portable-network-host-mismatch-resource))))
       (events (context-audit-events context))
       (decision (find-event-with-field
                  events 'capability-decision 'domain 'network)))
  (check 'portable-network-capability-denies-host-mismatch
         (and raised
              decision
              (equal? (field-value decision 'status) 'denied)
              (equal? (field-value decision 'grant) 'portable-network-grant)
              #t)
         #t))

(check 'portable-network-capability-handle-datums
       (list
        (network-capability-handle
         'h-network-1
         'req-network
         "https://api.example.test/events"
         'portable-network-grant
         'live)
        (network-port-capability-handle
         'p-network-1
         'textual-input
         'h-network-1
         '(read close)
         'portable-network-grant
         '((reads 2))
         'open))
       '((handle
          (id h-network-1)
          (kind network-stream)
          (domain network)
          (request req-network)
          (url "https://api.example.test/events")
          (grant portable-network-grant)
          (status live))
         (port-capability
          (id p-network-1)
          (kind textual-input)
          (backing network)
          (operations read close)
          (grant portable-network-grant)
          (limits (reads 2))
          (path h-network-1)
          (status open))))

(write-host-test-file port-test-input-path "abc")
(if (file-exists? port-test-output-path)
    (delete-file port-test-output-path))
(if (file-exists? port-test-call-output-path)
    (delete-file port-test-call-output-path))
(if (file-exists? port-test-with-output-path)
    (delete-file port-test-with-output-path))
(if (file-exists? port-test-close-output-path)
    (delete-file port-test-close-output-path))
(write-host-binary-file port-test-binary-input-path '(1 2 3 4 255))
(if (file-exists? port-test-binary-output-path)
    (delete-file port-test-binary-output-path))

(check-external/options 'standard-open-input-file-port-grant-allowed
                        "(import (scheme base) (scheme file))
                         (let ((port (open-input-file
                                      \"agent-scheme-port-input.scm\")))
                           (list (input-port? port)
                                 (textual-port? port)
                                 (read-string 2 port)
                                 (read-string 2 port)
                                 (eof-object? (read-char port))))"
                        file-port-grant-options
                        "(#t #t \"ab\" \"c\" #t)")

(check-external/options 'standard-open-output-file-port-grant-allowed
                        "(import (scheme base) (scheme file))
                         (let ((port (open-output-file
                                      \"agent-scheme-port-output.scm\")))
                           (write-string \"created\" port)
                           (close-port port)
                           (output-port-open? port))"
                        file-port-grant-options
                        "#f")

(check 'standard-open-output-file-writes-host-file
       (call-with-input-file port-test-output-path
         (lambda (port) (read-string 7 port)))
       "created")

(check-external/options 'standard-file-port-wrappers-use-capabilities
                        "(import (scheme base) (scheme file))
                         (list
                          (call-with-input-file
                           \"agent-scheme-port-input.scm\"
                           (lambda (port) (read-string 3 port)))
                          (with-input-from-file
                           \"agent-scheme-port-input.scm\"
                           (lambda () (read-string 3)))
                          (begin
                            (call-with-output-file
                             \"agent-scheme-port-call-output.scm\"
                             (lambda (port) (write-string \"call\" port)))
                            'call-done)
                          (begin
                            (with-output-to-file
                             \"agent-scheme-port-with-output.scm\"
                             (lambda () (write-string \"with\")))
                            'with-done))"
                        file-port-grant-options
                        "(\"abc\" \"abc\" call-done with-done)")

(check 'standard-call-output-file-writes-host-file
       (call-with-input-file port-test-call-output-path
         (lambda (port) (read-string 4 port)))
       "call")

(check 'standard-with-output-file-writes-host-file
       (call-with-input-file port-test-with-output-path
         (lambda (port) (read-string 4 port)))
       "with")

(check 'standard-current-output-port-default-denied
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (current-output-port)")))
       #t)

(check 'standard-file-port-close-invalidates-handle
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file))
            (let ((port (open-input-file
                         \"agent-scheme-port-input.scm\")))
              (close-port port)
              (read-char port))"
           #f
           file-port-grant-options)))
       #t)

(check 'standard-file-port-revoked-grant-is-stale
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file) (agent capability))
            (grant-capability!
             '(capability-grant
               (id portable-revoked-port-grant)
               (domain file)
               (operations read)
               (scope (file-root \"/tmp\")
                      (paths (\"agent-scheme-port-input.scm\"))
                      (remote denied)
                      (symlinks portable-unresolved))
               (expires never)))
            (let ((port (open-input-file
                         \"agent-scheme-port-input.scm\")))
              (grant-revoke! 'portable-revoked-port-grant)
              (read-char port))"
           #f
           '((include-directory . "/tmp")))))
       #t)

(check 'standard-file-port-read-limit-is-enforced
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file) (agent capability))
            (grant-capability!
             '(capability-grant
               (id portable-limited-port-grant)
               (domain file)
               (operations read)
               (scope (file-root \"/tmp\")
                      (paths (\"agent-scheme-port-input.scm\"))
                      (remote denied)
                      (symlinks portable-unresolved))
               (limits (reads 1))
               (expires never)))
            (let ((port (open-input-file
                         \"agent-scheme-port-input.scm\")))
              (read-char port)
              (read-char port))"
           #f
           '((include-directory . "/tmp")))))
       #t)

(check-external/options 'standard-file-port-close-limit-allows-close
                        "(import (scheme base) (scheme file)
                                 (agent capability))
                         (grant-capability!
                          '(capability-grant
                            (id portable-close-limited-port-grant)
                            (domain file)
                            (operations create)
                            (scope (file-root \"/tmp\")
                                   (paths
                                    (\"agent-scheme-port-close-output.scm\"))
                                   (remote denied)
                                   (symlinks portable-unresolved))
                            (limits (closes 1))
                            (expires never)))
                         (let ((port (open-output-file
                                      \"agent-scheme-port-close-output.scm\")))
                           (write-string \"x\" port)
                           (close-port port)
                           (output-port-open? port))"
                        '((include-directory . "/tmp"))
                        "#f")

(check 'standard-file-port-close-limit-writes-host-file
       (call-with-input-file port-test-close-output-path
         (lambda (port) (read-string 1 port)))
       "x")

(check-external/options 'standard-open-binary-file-port-grant-allowed
                        "(import (scheme base) (scheme file))
                         (let ((in (open-binary-input-file
                                    \"agent-scheme-port-input.bin\"))
                               (out (open-binary-output-file
                                     \"agent-scheme-port-output.bin\")))
                           (write-u8 (read-u8 in) out)
                           (write-bytevector (read-bytevector 4 in) out)
                           (close-port out)
                           (list (binary-port? in)
                                 (eof-object? (read-u8 in))
                                 (output-port-open? out)))"
                        file-port-grant-options
                        "(#t #t #f)")

(check 'standard-open-binary-output-file-writes-host-file
       (read-host-binary-file port-test-binary-output-path)
       '(1 2 3 4 255))

(check 'standard-file-grant-denies-path-traversal
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"fixtures/r7rs/../../AGENTS.md\")"
           #f
           file-grant-options)))
       #t)

(check 'standard-file-grant-denies-url-paths
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base) (scheme file))
            (file-exists? \"https://example.invalid/source.scm\")"
           #f
           file-grant-options)))
       #t)

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (scheme file))
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
         #f
         file-grant-options))
       (events (field-value result 'events))
       (request (find-event events 'capability-request))
       (decision (find-event events 'capability-decision))
       (handle (find-event-with-field
                events 'capability-handle 'domain 'file))
       (audit (find-event events 'capability-audit)))
  (check 'standard-file-grant-audits-request-decision-result
         (and request
              decision
              handle
              audit
              (equal? (field-value request 'domain) 'file)
              (equal? (field-value request 'operation) 'metadata)
              (equal? (field-value decision 'status) 'approved)
              (equal? (field-value decision 'grant) 'portable-file-grant)
              (equal? (field-value handle 'kind) 'file)
              (equal? (field-value handle 'grant) 'portable-file-grant)
              (equal? (field-value handle 'status) 'live)
              (equal? (field-value audit 'result) '(ok #t))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (scheme file) (agent capability))
          (grant-revoke! 'portable-file-grant)
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
         #f
         file-grant-options))
       (events (field-value result 'events))
       (revocation (find-event events 'capability-revocation))
       (decision (find-event-with-field
                  events 'capability-decision 'status 'denied)))
  (check 'standard-file-grant-revocation-audits
         (and (equal? (field-value result 'status) 'error)
              revocation
              decision
              (equal? (field-value revocation 'target)
                      '(grant portable-file-grant))
              (equal? (field-value revocation 'status) 'revoked)
              (equal? (field-value decision 'grant) 'portable-file-grant)
              #t)
         #t))

(let* ((result
       (agent-scheme-eval-source-result
         "(import (scheme base) (scheme file))
          (file-exists? \"fixtures/r7rs/conformance-cases.scm\")"
         #f
         include-policy-options))
       (events (field-value result 'events))
       (event (find-event events 'policy-decision)))
  (check 'standard-file-policy-allowed-audits
         (and event
              (equal? (field-value event 'event) 'policy-decision)
              (equal? (field-value event 'category) 'standard-host-effect)
              (equal? (field-value event 'operation) "file-exists?")
              (equal? (field-value event 'decision) 'allowed)
              (equal? (field-value event 'filename)
                      "fixtures/r7rs/conformance-cases.scm")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent io))
          (agent-yield '(first 1))
          (agent-yield '(second 2))
          42"))
       (events (field-value result 'events)))
  (check 'agent-io-yields-are-ordered-result-events
         (and (equal? (field-value result 'status) 'ok)
              (string=? (agent-scheme-value->external
                         (field-value result 'value))
                        "42")
              (string=? (agent-scheme-result->external
                         (list 'events events))
                        "(events ((yield (first 1)) (yield (second 2))))")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent io))
          (agent-log 'info \"starting\" '(scope test))
          (agent-progress 'reader '(parsed 2))
          (agent-warn \"careful\" '(kind stale-handle))
          (agent-request '(approval (policy buffer-edit)))
          'done"))
       (events (field-value result 'events)))
  (check 'agent-io-core-events-render-in-result
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-result->external (list 'events events))
               (string-append
                "(events ((log (level info) (message \"starting\") "
                "(fields ((scope test)))) "
                "(progress (phase reader) (datum (parsed 2))) "
                "(warn (message \"careful\") "
                "(fields ((kind stale-handle)))) "
                "(request (approval (policy buffer-edit)))))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent io))
          (agent-yield '(first))
          (agent-yield '(second))
          'unreachable"
         #f
         '((max-events . 1))))
       (events (field-value result 'events))
       (error-field (assq 'error (cdr result))))
  (check 'agent-io-event-count-limit-fails-closed
         (and (equal? (field-value result 'status) 'error)
              (string=? (agent-scheme-result->external
                         (list 'events events))
                        "(events ((yield (first))))")
              (string=? (field-value error-field 'message)
                        "agent-scheme budget error: event count budget exceeded")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent io))
          (agent-yield '(too many nodes))"
         #f
         '((max-event-nodes . 2))))
       (events (field-value result 'events))
       (error-field (assq 'error (cdr result))))
  (check 'agent-io-event-node-limit-fails-closed
         (and (equal? (field-value result 'status) 'error)
              (null? events)
              (string=? (field-value error-field 'message)
                        "agent-scheme budget error: event node budget exceeded")
         #t)
         #t))

(let ((external
       (agent-scheme-value->external
        (agent-scheme-eval-source
         "(import (scheme base) (agent io) (agent reflect))
          (agent-yield '(first 1))
          (list (capability-info 'file-exists?)
                (current-budget)
                (current-imports)
                (recent-yields))"
         #f
         '((max-steps . 777)
           (max-host-callbacks . 66)
           (max-events . 4)
           (max-event-nodes . 44))))))
  (check 'agent-reflect-capability-budget-imports-and-yields
         (and (string-contains? external "(host-capability")
              (string-contains? external "(library (scheme file))")
              (string-contains? external "(name file-exists?)")
              (string-contains? external "(max-steps 777)")
              (string-contains? external "(max-host-calls 66)")
              (string-contains? external "(max-events 4)")
              (string-contains? external "(max-event-nodes 44)")
              (string-contains? external "(agent reflect)")
              (string-contains? external "(yield (first 1))")
              #t)
         #t))

(let ((external
       (agent-scheme-value->external
        (agent-scheme-eval-source
         "(import (scheme base) (agent io) (agent reflect))
          (agent-yield '((source env)
                         (field \"OPENAI_API_KEY\")
                         (value \"sk-portablereflect1234567890\")))
          (recent-yields)"))))
  (check 'agent-reflect-recent-yields-redacts-secrets
         (and (string-contains? external "(redaction (kind secret)")
              (not (string-contains? external "sk-portablereflect"))
              #t)
         #t))

(check 'agent-diff-proposed-edit-renders
       (agent-scheme-eval-source
        "(import (agent diff))
         (diff-render-unified
          (proposed-edit-diff
           '(proposed-edit
             (source buffer)
             (old-label \"before.scm\")
             (new-label \"after.scm\")
             (start 2)
             (end 2)
             (before \"old\")
             (after \"new\"))))")
       "--- before.scm\n+++ after.scm\n@@ -2,1 +2,1 @@\n-old\n+new\n")

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent diff))
          (diff-yield (no-change-diff 'buffer \"scratch\"))
          'ok"))
       (events (field-value result 'events)))
  (check 'agent-diff-yield-records-event
         (and (equal? (field-value result 'status) 'ok)
              (string=? (agent-scheme-result->external
                         (list 'events events))
                        (string-append
                         "(events ((yield (diff (source buffer) "
                         "(old-label \"scratch\") "
                         "(new-label \"scratch\") "
                         "(status no-change) (hunks ())))))"))
              #t)
         #t))

(check-external 'agent-vcs-status-parser
                "(import (scheme base) (agent vcs))
                 (define nul (string #\\null))
                 (define status
                   (parse-git-status-porcelain-v2-z
                    (string-append
                     \"# branch.oid abc123\" nul
                     \"# branch.head main\" nul
                     \"# branch.upstream origin/main\" nul
                     \"# branch.ab +2 -1\" nul
                     \"1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb src/main.scm\" nul
                     \"? scratch.scm\" nul)))
                 (define branch (vcs-status-branch status))
                 (define entries (vcs-status-entries status))
                 (list
                  (vcs-field-value branch 'head #f)
                  (vcs-field-value branch 'ahead 0)
                  (vcs-field-value branch 'behind 0)
                  (vcs-field-value (car entries) 'kind #f)
                  (vcs-field-value (car entries) 'path #f)
                  (vcs-field-value (cadr entries) 'kind #f))"
                "(\"main\" 2 1 modified \"src/main.scm\" untracked)")

(check-external 'agent-vcs-raw-diff-parser
                "(import (scheme base) (agent vcs))
                 (define nul (string #\\null))
                 (define diff
                   (parse-git-raw-diff-z
                    (string-append
                     \":100644 100644 abcdef1 1234567 M\" nul
                     \"src/main.scm\" nul)))
                 (let ((file (car (vcs-diff-summary-files diff))))
                   (list
                    (vcs-field-value file 'status #f)
                    (vcs-field-value file 'path #f)
                    (vcs-field-value file 'old-object #f)
                    (vcs-field-value file 'new-object #f)))"
                "(modified \"src/main.scm\" \"abcdef1\" \"1234567\")")

(check-external 'agent-vcs-local-mutation-authorization
                "(import (scheme base) (agent vcs))
                 (define request
                   (make-vcs-capability-request
                    'req-stage
                    'stage
                    'repository-mutation
                    '((repository \"/repo\") (paths (\"src/main.scm\")))))
                 (define denied
                   (vcs-authorize-capability-request request '() '()))
                 (define grant
                   (make-vcs-capability-grant
                    'grant-local
                    'repository-mutation
                    '(stage commit)
                    \"/repo\"
                    #f))
                 (define allowed
                   (vcs-authorize-capability-request request (list grant) '()))
                 (define result
                   (make-vcs-capability-result
                    'req-stage
                    'ok
                    (make-vcs-outcome 'ok \"Staged selected paths.\")))
                 (define audit
                   (make-vcs-capability-audit request allowed result))
                 (list
                  (vcs-mutating-operation? 'stage)
                  (vcs-remote-operation? 'stage)
                  (vcs-operation-required-authority 'stage)
                  (vcs-capability-request? request)
                  (vcs-field-value request 'required-authority #f)
                  (vcs-capability-decision-status denied)
                  (vcs-field-value denied 'reason #f)
                  (vcs-capability-decision-status allowed)
                  (vcs-field-value allowed 'grant #f)
                  (vcs-field-value audit 'event #f)
                  (vcs-field-value audit 'decision #f)
                  (vcs-field-value audit 'result #f)
                  (vcs-field-value audit 'outcome #f))"
                "(#t #f repository-mutation #t repository-mutation denied \"missing VCS mutation grant or approval\" approved grant-local vcs-capability-audit approved ok ok)")

(check-external 'agent-vcs-remote-mutation-authorization
                "(import (scheme base) (agent vcs))
                 (define request
                   (make-vcs-capability-request
                    'req-push
                    'push
                    'remote-mutation
                    '((repository \"/repo\") (remote \"origin\") (branch \"main\"))))
                 (define local-grant
                   (make-vcs-capability-grant
                    'grant-local
                    'repository-mutation
                    '(stage commit)
                    \"/repo\"
                    #f))
                 (define denied
                   (vcs-authorize-capability-request request (list local-grant) '()))
                 (define approval
                   (make-vcs-approval-decision
                    'approve-push
                    'req-push
                    'approved
                    \"User approved push.\"))
                 (define allowed
                   (vcs-authorize-capability-request request '() (list approval)))
                 (define result
                   (make-vcs-capability-result
                    'req-push
                    'error
                    (make-vcs-outcome
                     'remote-authentication-failed
                     \"Remote rejected credentials.\")))
                 (define audit
                   (make-vcs-capability-audit request allowed result))
                 (list
                  (vcs-remote-operation? 'push)
                  (vcs-operation-required-authority 'push)
                  (vcs-capability-decision-status denied)
                  (vcs-capability-decision-status allowed)
                  (vcs-field-value allowed 'approval #f)
                  (vcs-field-value request 'remote? #f)
                  (vcs-field-value audit 'remote? #f)
                  (vcs-field-value audit 'outcome #f)
                  (vcs-known-outcome? 'remote-authentication-failed)
                  (vcs-known-outcome? 'remote-unavailable))"
                "(#t remote-mutation denied approved approve-push #t #t remote-authentication-failed #t #t)")

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent approval))
          (define id
            (approval-request!
             '(approval-request
                (policy buffer-edit)
                (effect (buffer-replace! h-1 1 2 \"x\"))
                (reason \"Replace text?\"))))
          (list id (approval-status id))"))
       (value (field-value result 'value)))
  (check 'agent-approval-request-status
         (and (equal? (field-value result 'status) 'ok)
              (string=? (agent-scheme-value->external value)
                        "(a-1 pending)")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent approval))
          (approval-request!
           '(approval-request
              (policy buffer-edit)
              (effect (buffer-delete! h-1 1 2))
              (reason \"Delete text?\")))
          (approval-yield-pending)
          'done"))
       (events (field-value result 'events)))
  (check 'agent-approval-yield-pending
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-result->external (list 'events events))
               (string-append
                "(events ((yield (approval-request (id a-1) "
                "(policy buffer-edit) "
                "(effect (buffer-replace! h-1 1 2 \"x\")) "
                "(reason \"Replace text?\") "
                "(status pending))) "
                "(yield (approval-request (id a-2) "
                "(policy buffer-edit) "
                "(effect (buffer-delete! h-1 1 2)) "
                "(reason \"Delete text?\") "
                "(status pending)))))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent approval))
          (define id
            (approval-request!
             '(approval-request
                (policy buffer-edit)
                (effect (buffer-insert! h-1 1 \"x\"))
                (reason \"Insert text?\"))))
          (approval-resolve! id 'approved)"))
       (error-field (assq 'error (cdr result))))
  (check 'agent-approval-self-approval-denied
         (and (equal? (field-value result 'status) 'error)
              (string=? (field-value error-field 'message)
                        "agent-scheme eval error: approval resolution is host-side only")
         #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent redaction))
          (let ((secret '((source env)
                          (field \"OPENAI_API_KEY\")
                          (value \"sk-portableagent1234567890\"))))
            (list (secret-source? secret)
                  (redact secret 'remote-provider)
                  (safe-for-provider? secret 'openai)))"))
       (value (field-value result 'value)))
  (check 'agent-redaction-secret-source-redact-provider
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-value->external value)
               (string-append
                "(#t (redaction (kind secret) (source env) "
                "(field \"OPENAI_API_KEY\") "
                "(replacement \"[redacted]\") "
                "(policy local-only)) #f)"))
              #t)
         #t))

(check-external
 'agent-models-register-and-route
 "(import (scheme base) (agent models))
  (model-provider-register!
   '(model-provider
     (id portable-local)
     (kind local)
     (transport openai-compatible-http)
     (endpoint \"http://127.0.0.1:11434/v1\")
     (models
      (((id portable-coder)
        (roles (scheme-scripter code))
        (privacy local))))))
  (model-route 'scheme-scripter '())"
 "(model-routing-decision (status selected) (role scheme-scripter) (provider portable-local) (model portable-coder) (kind local) (transport openai-compatible-http) (endpoint \"http://127.0.0.1:11434/v1\"))")

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent capability))
          (grant-capability!
           '(capability-grant
              (id portable-grant)
              (library (emacs buffer edit))
              (effect buffer-replace!)
              (scope (range 1 2))
              (expires after-eval)))
          (list (grant-ref 'portable-grant)
                (current-grants))"))
       (value (field-value result 'value)))
  (check 'agent-capability-grant-datums
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-value->external value)
               (string-append
                "((capability-grant (id portable-grant) "
                "(library (emacs buffer edit)) "
                "(effect buffer-replace!) (scope (range 1 2)) "
                "(expires after-eval) (status active)) "
                "((capability-grant (id portable-grant) "
                "(library (emacs buffer edit)) "
                "(effect buffer-replace!) (scope (range 1 2)) "
                "(expires after-eval) (status active))))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent capability))
          (grant-capability!
           '(capability-grant
              (id portable-parent-grant)
              (library (emacs buffer edit))
              (effect buffer-replace!)
              (scope (range 1 9))
              (expires never)))
          (define child
            (grant-attenuate
             'portable-parent-grant
             '((id portable-child-grant)
               (scope (range 2 4))
               (expires after-eval))))
          (grant-revoke! 'portable-parent-grant)
          (with-capability-grant child
            (grant-ref 'portable-child-grant))"))
       (value (field-value result 'value)))
  (check 'agent-capability-attenuate-revoke-with-grant
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-value->external value)
               (string-append
                "(capability-grant (library (emacs buffer edit)) "
                "(effect buffer-replace!) (scope (range 2 4)) "
                "(expires after-eval) (id portable-child-grant) "
                "(parent portable-parent-grant) (status active))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent memory))
          (memory-put! 'instance
                       'portable-alpha
                       '((tags (portable fact))
                         (value \"portable alpha\")
                         (confidence high)))
          (memory-add! 'project
                       'fact
                       '((tags (project portable))
                         (value \"project portable\")))
          (list (memory-ref 'instance 'portable-alpha)
                (memory-by-tag 'project 'project)
                (memory-find 'instance \"portable alpha\"))"))
       (value (field-value result 'value)))
  (check 'agent-memory-crud-search-tags
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-value->external value)
               (string-append
                "((memory (id portable-alpha) (scope instance) "
                "(key portable-alpha) (kind datum) "
                "(tags (portable fact)) (value \"portable alpha\") "
                "(source ()) (confidence high) (created-at 1) "
                "(updated-at 1)) "
                "((memory (id m-2) (scope project) (key m-2) "
                "(kind fact) (tags (project portable)) "
                "(value \"project portable\") (source ()) "
                "(confidence unknown) (created-at 2) (updated-at 2))) "
                "((memory (id portable-alpha) (scope instance) "
                "(key portable-alpha) (kind datum) "
                "(tags (portable fact)) (value \"portable alpha\") "
                "(source ()) (confidence high) (created-at 1) "
                "(updated-at 1))))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent memory))
          (memory-put! 'instance
                       'portable-yield
                       '((tags (portable))
                         (value \"yield portable\")))
          (memory-yield 'instance \"yield portable\")
          'done"))
       (events (field-value result 'events)))
  (check 'agent-memory-yield-emits-agent-event
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-result->external (list 'events events))
               (string-append
                "(events ((yield (memory (id portable-yield) "
                "(scope instance) (key portable-yield) "
                "(kind datum) (tags (portable)) "
                "(value \"yield portable\") (source ()) "
                "(confidence unknown) (created-at 3) "
                "(updated-at 3)))))"))
         #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent helper))
          (agent-helper-save!
           '(agent helpers portable)
           '((define (portable-helper x) (+ x 1)))
           '((scope project-private)))
          (agent-helper-load '(agent helpers portable)
                             '((scope project-private)))
          (list (portable-helper 41)
                (agent-helper-list 'project-private))"))
       (value (field-value result 'value)))
  (check 'agent-helper-save-list-load
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (agent-scheme-value->external value)
               "(42 ((agent-helper-library")
              (string-contains?
               (agent-scheme-value->external value)
               "(name (agent helpers portable))")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent helper))
          (agent-artifact
           'example
           '(example (source \"(portable-helper 41)\") (expect \"42\")))
          (agent-helper-save!
           '(agent helpers candidate)
           '((define (portable-candidate) 'ok))
           '((scope project-private)))
          (agent-helper-promote-to-skill
           '(agent helpers candidate)
           '((scope project-private)
             (name \"portable-candidate\")
             (examples ((example (source \"(portable-candidate)\")
                                 (expect \"ok\"))))
             (references ((r7rs \"docs/r7rs-small-report.md\")))
             (tests (((source \"(portable-candidate)\")
                      (expect \"ok\"))))))"))
       (events (field-value result 'events))
       (value (field-value result 'value)))
  (check 'agent-helper-artifact-and-skill-candidate
         (and (equal? (field-value result 'status) 'ok)
              (equal? (car value) 'agent-skill-candidate)
              (string-contains?
               (agent-scheme-value->external value)
               "(name \"portable-candidate\")")
              (string-contains?
               (agent-scheme-result->external (list 'events events))
               "(yield (agent-artifact")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent test))
          (define run
            (test-group 'portable-arithmetic
              (test-case 'passes (+ 1 1) 2)
              (test-case 'fails (+ 1 1) 3)
              (test-error 'expected-error (error \"boom\") error-object?)))
          (test-run 'portable-arithmetic)"))
       (value (field-value result 'value)))
  (check 'agent-test-group-results
         (and (equal? (field-value result 'status) 'ok)
              (equal? (car value) 'agent-test-group)
              (string-contains?
               (agent-scheme-value->external value)
               "(summary (total 3) (pass 2) (fail 1) (error 0) (skipped 0) (budget-exhausted 0))")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent test) (agent io))
          (define run
            (test-group 'portable-yield
              (test-case 'bad (+ 1 1) 3)))
          (test-yield-failures run)
          'done"))
       (events (field-value result 'events)))
  (check 'agent-test-yield-failures
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (agent-scheme-result->external (list 'events events))
               "(yield (agent-test-failures")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent test))
          (skill-test
           'portable-skill
           '((name source-pass)
             (source \"(import (scheme base)) (+ 20 22)\")
             (expect \"42\")))
          (skill-test
           'portable-skill
           '(srfi-64 (test-name srfi-pass) (result pass)))
          (skill-test-run 'portable-skill)"))
       (value (field-value result 'value)))
  (check 'agent-test-skill-and-srfi64
         (and (equal? (field-value result 'status) 'ok)
              (equal? (car value) 'agent-test-group)
              (string-contains?
               (agent-scheme-value->external value)
               "(kind skill)")
              (string-contains?
               (agent-scheme-value->external value)
               "(summary (total 2) (pass 2) (fail 0) (error 0) (skipped 0) (budget-exhausted 0))")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent test))
          (skill-test
           'portable-budget
           '((name budgeted-loop)
             (source \"(define (loop) (loop)) (loop)\")
             (expect ok)
             (options ((max-steps 20)))))
          (skill-test-run 'portable-budget)"))
       (value (field-value result 'value)))
  (check 'agent-test-budget-exhaustion-status
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (agent-scheme-value->external value)
               "(status budget-exhausted)")
              (string-contains?
               (agent-scheme-value->external value)
               "(summary (total 1) (pass 0) (fail 0) (error 0) (skipped 0) (budget-exhausted 1))")
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent plan))
          (plan-create!
           '(plan
              (id portable-plan)
              (scope project)
              (goal \"Expose portable planning data\")
              (steps (((id first) (status pending))))))
          (plan-step-add!
           'portable-plan
           '((id second) (status pending) (goal \"Check portability\")))
          (plan-step-status! 'portable-plan 'first 'done)
          (plan-status! 'portable-plan 'active)
          (plan-ref 'portable-plan)"))
       (value (field-value result 'value)))
  (check 'agent-plan-crud-step-status
         (and (equal? (field-value result 'status) 'ok)
              (string=?
               (agent-scheme-value->external value)
               (string-append
                "(plan (id portable-plan) (scope project) "
                "(status active) "
                "(goal \"Expose portable planning data\") "
                "(steps (((id first) (status done)) "
                "((id second) (status pending) "
                "(goal \"Check portability\")))) "
                "(created-at 1) (updated-at 4))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent plan))
          (plan-create!
           '(plan
              (id portable-yield)
              (scope project)
              (goal \"Yield portable plan\")
              (steps ())))
          (plan-yield 'portable-yield)
          'done"))
       (events (field-value result 'events)))
  (check 'agent-plan-yield-emits-agent-event
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (agent-scheme-result->external (list 'events events))
               (string-append
                "(yield (plan (id portable-yield) "
                "(scope project) (status pending) "
                "(goal \"Yield portable plan\") (steps ()) "
                "(created-at 5) (updated-at 5)))"))
              #t)
         #t))

(let* ((result
        (agent-scheme-eval-source-result
         "(import (scheme base) (agent context))
          (context-yield 'request)
          (list (current-request)
                (current-conversation-summary)
                (current-focus)
                (current-buffer-context))"
         #f
         '((request-id . portable-req)
           (request . "portable context request")
           (conversation-summary . "portable conversation summary"))))
       (events (field-value result 'events))
       (value (field-value result 'value)))
  (check 'agent-context-portable-request-summary-focus-and-yield
         (and (equal? (field-value result 'status) 'ok)
              (string-contains?
               (agent-scheme-value->external value)
               "(request-context (request-id portable-req) (request \"portable context request\"))")
              (string-contains?
               (agent-scheme-value->external value)
               "(conversation-summary (summary \"portable conversation summary\"))")
              (string-contains?
               (agent-scheme-value->external value)
               "(focus-context")
              (string-contains?
               (agent-scheme-result->external (list 'events events))
               "(yield (request-context")
              #t)
         #t))

(check 'standard-host-libraries-import-and-default-deny
       (and
        (not
         (raises?
          (lambda ()
            (agent-scheme-eval-source
             "(import (scheme process-context) (scheme time) (scheme repl))
              'ok"))))
        (raises?
         (lambda ()
           (agent-scheme-eval-source
            "(import (scheme base) (scheme process-context))
             (command-line)")))
        (raises?
         (lambda ()
           (agent-scheme-eval-source
            "(import (scheme base) (scheme time))
             (current-second)")))
        (raises?
         (lambda ()
           (agent-scheme-eval-source
            "(import (scheme base) (scheme repl))
             (interaction-environment)"))))
       #t)

(check-external 'standard-r5rs-import
                "(import (scheme r5rs))
                 (list (+ 1 2)
                       (exact->inexact 3)
                       (inexact->exact 3.0))"
                "(3 3.0 3)")

(check 'imported-value-set-is-rejected
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (set! + 1)"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'imported-value-define-is-rejected
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (define + 1)"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'imported-syntax-define-is-rejected
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            (define-syntax and
              (syntax-rules ()
                ((and) #t)))"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'duplicate-export-names-signal-error
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(define-library (agent-scheme fixture duplicate-export)
              (export value value)
              (import (scheme base))
              (begin (define value 1)))")))
       #t)

(check 'program-imports-precede-body
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(import (scheme base))
            1
            (import (scheme cxr))
            'ok"
           (agent-scheme-make-empty-environment))))
       #t)

(check 'expand-source-exposes-expanded-forms
       (agent-scheme-value->external
        (agent-scheme-expand-source
         "(define-syntax unless
            (syntax-rules ()
              ((unless test body ...)
               (if test #f (begin body ...)))))
          (unless #f 42)"))
       "((if #f #f (begin 42)))")

(check 'syntax-error-reports-source-form
       (let* ((result
               (agent-scheme-eval-source-result
                "(define-syntax bad-use
                   (syntax-rules ()
                     ((bad-use x)
                      (syntax-error \"bad macro\" x))))
                 (bad-use 123)"))
              (error-field (assq 'error (cdr result)))
              (message-field (assq 'message (cdr error-field))))
         (cadr message-field))
       "agent-scheme eval error: syntax-error while expanding (bad-use 123): \"bad macro\" 123")

(check 'result-rendering
       (agent-scheme-result->external
        (agent-scheme-eval-source-result "(+ 1 2)"))
       "(evaluation-result (status ok) (value 3) (events ()) (budget (steps-used 5) (host-calls 1)))")

(check-external 'closure
                "(define make-adder
                   (lambda (x)
                     (lambda (y) (+ x y))))
                 ((make-adder 4) 6)"
                "10")
(check-external 'internal-variable-definition
                "((lambda (x)
                    (define y 2)
                    (+ x y))
                  3)"
                "5")
(check-external 'internal-function-definition
                "((lambda (x)
                    (define (twice y) (+ y y))
                    (twice x))
                  5)"
                "10")
(check-external 'internal-definition-shadows-parent
                "((lambda ()
                    (define + (lambda (x y) x))
                    (+ 1 2)))"
                "1")

(let ((parent (agent-scheme-make-base-environment))
      (child #f))
  (set! child (agent-scheme-make-empty-environment parent))
  (check 'child-definition-shadows-parent
         (agent-scheme-value->external
          (agent-scheme-eval-source
           "(define + (lambda (x y) y))
            (+ 1 2)"
           child))
         "2")
  (check 'parent-primitive-remains-bound
         (agent-scheme-value->external
          (agent-scheme-eval-source "(+ 1 2)" parent))
         "3"))

(check-external 'set-mutates-local
                "((lambda (x)
                    (set! x (+ x 1))
                    x)
                  2)"
                "3")
(check-external 'set-mutates-captured
                "(define make-counter
                   (lambda ()
                     (define x 0)
                     (lambda ()
                       (set! x (+ x 1))
                       x)))
                 (define counter (make-counter))
                 (counter)
                 (counter)"
                "2")
(check 'set-unbound
       (raises? (lambda () (agent-scheme-eval-source "(set! missing 1)")))
       #t)

(check-external 'scheme-truthiness-false "(if #f 1 2)" "2")
(check-external 'scheme-truthiness-empty-list "(if '() 1 2)" "1")
(check-external 'if-without-alternate "(if #f 1)" "#<unspecified>")

(check-external 'variadic-formals "((lambda x x) 3 4 5)" "(3 4 5)")
(check-external 'dotted-formals
                "((lambda (x y . z) z) 3 4 5 6)"
                "(5 6)")
(check 'duplicate-formals
       (raises? (lambda ()
                  (agent-scheme-eval-source "((lambda (x x) x) 1 2)")))
       #t)
(check 'arity-error
       (raises? (lambda ()
                  (agent-scheme-eval-source "((lambda (x) x) 1 2)")))
       #t)

(check-external/options 'tail-recursive-loop
                        "(define (loop n acc)
                           (if (= n 0)
                               acc
                               (loop (- n 1) (+ acc 1))))
                         (loop 5000 0)"
                        '((max-steps . 100000)
                          (max-host-callbacks . 30000))
                        "5000")

(check 'step-budget
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(define (loop n) (loop n))
            (loop 0)"
           #f
           '((max-steps . 40)))))
       #t)
(check 'value-budget
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "'(1 2 3)"
           #f
           '((max-value-nodes . 2)))))
       #t)
(check 'host-callback-budget
       (raises?
        (lambda ()
          (agent-scheme-eval-source
           "(+ 1 2)"
           #f
           '((max-host-callbacks . 0)))))
       #t)

(if (= failures 0)
    (begin
      (display "Scheme evaluator tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme evaluator test failure(s)")
      (newline)
      (error "Scheme evaluator tests failed")))
