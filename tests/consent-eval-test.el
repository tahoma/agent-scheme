;;; consent-eval-test.el --- R7RS evaluator kernel tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused tests for the Emacs Lisp evaluator kernel. Shared external evaluator
;; behavior runs through the canonical fixture corpus; these tests keep
;; host-side environment mutation, closure identity, continuation machinery,
;; budgets, and library internals close to the implementation.

;;; Code:

(require 'ert)
(require 'consent-eval)

(defun consent-eval-test--external (source &optional options)
  "Evaluate SOURCE and return the external representation of its value."
  (consent-value->external
   (consent-eval-source source nil options)))

(defun consent-eval-test--result-external (source &optional options)
  "Evaluate SOURCE and return the external representation of its result record."
  (consent-result->external
   (consent-eval-source-result source nil options)))

(ert-deftest consent-eval-test-literals-and-quote ()
  "Evaluate self-evaluating datums and quoted datums."
  (should (equal (consent-eval-test--external "42") "42"))
  (should (equal (consent-eval-test--external "#t") "#t"))
  (should (equal (consent-eval-test--external "\"ok\"") "\"ok\""))
  (should (equal (consent-eval-test--external "'alpha") "alpha"))
  (should (equal (consent-eval-test--external "'(1 2 3)") "(1 2 3)"))
  (should-error (consent-eval-source "()")
                :type 'consent-eval-error))

(ert-deftest consent-eval-test-process-environment-capability ()
  "Environment reads are denied by default and supplied under a grant.
An unset variable read under the process-environment grant returns #f rather
than raising, which keeps the allow path deterministic."
  (should-error
   (consent-eval-source
    "(import (scheme base) (scheme process-context))
     (get-environment-variable \"CONSENT_UNSET_ENV_PROBE\")")
   :type 'consent-eval-error)
  (should
   (equal
    (consent-eval-test--external
     "(import (scheme base) (scheme process-context))
      (get-environment-variable \"CONSENT_UNSET_ENV_PROBE\")"
     '(:capability-grants
       ((capability-grant
         (id host-environment)
         (domain process-environment)
         (operations read)
         (expires never)))))
    "#f")))

(ert-deftest consent-eval-test-program-input-stream ()
  "Program input connects current-input-port only under a stdin-backed port grant.
A `:program-input-reader' plus an active `port'/`read' grant scoped to `stdin'
lets `read-line'/`read-char'/`read' draw from the program input; without the
grant the read fails closed exactly as an unconnected current input port does,
and offering a reader with no grant stays disconnected.  Parity twin of the
portable `program-input-granted-read-line' check."
  (let ((grants '((capability-grant
                   (id program-input)
                   (domain port)
                   (operations read close)
                   (scope (backing stdin))
                   (expires never)))))
    ;; Granted: read-line draws the first line from the program input.
    (should (equal (consent-eval-test--external
                    "(read-line)"
                    (list :program-input-reader
                          (consent-program-input-from-string "alpha\nbeta\n")
                          :capability-grants grants))
                   "\"alpha\""))
    ;; Granted: successive reads advance over the input to EOF.
    (should
     (equal
      (consent-eval-test--external
       "(list (read-line) (read-line) (read-char) (eof-object? (read-line)))"
       (list :program-input-reader
             (consent-program-input-from-string "a\nb\nc")
             :capability-grants grants))
      "(\"a\" \"b\" #\\c #t)"))
    ;; Ungranted: a reader offered but no grant -> read fails closed.
    (should-error
     (consent-eval-source
      "(read-line)" nil
      (list :program-input-reader
            (consent-program-input-from-string "alpha\n")))
     :type 'consent-eval-error)
    ;; Grant present but no reader offered -> still disconnected (fail closed).
    (should-error
     (consent-eval-source
      "(read-line)" nil (list :capability-grants grants))
     :type 'consent-eval-error)))

(ert-deftest consent-eval-test-program-input-streaming ()
  "Program input is pulled from a host reader thunk on demand.
A `:program-input-reader' yields the next chunk (or nil at end of stream), so a
read consumes only as much input as it needs and an unbounded stream never
drains up front.  Parity twin of the portable `program-input-stream-read-line'
checks."
  (let ((grants '(:capability-grants
                  ((capability-grant
                    (id program-input) (domain port) (operations read close)
                    (scope (backing stdin)) (expires never))))))
    ;; Incremental: reading one line pulls exactly one chunk, not the stream.
    (let* ((pulls 0)
           (chunks (list "a\n" "b\n" "c\n"))
           (reader (lambda ()
                     (setq pulls (1+ pulls))
                     (and chunks (pop chunks)))))
      (should (equal (consent-eval-test--external
                      "(read-line)"
                      (append (list :program-input-reader reader) grants))
                     "\"a\""))
      (should (= pulls 1)))
    ;; An unbounded reader would hang here if the port drained eagerly; reading
    ;; a bounded number of lines completes because refills stop at each newline.
    (should (equal (consent-eval-test--external
                    "(list (read-line) (read-line) (read-line))"
                    (append (list :program-input-reader (lambda () "x\n")) grants))
                   "(\"x\" \"x\" \"x\")"))
    ;; A datum split across chunks is assembled by refilling until the recovery
    ;; reader sees a complete form.
    (let* ((chunks (list "(1 2" " 3 " "4)"))
           (reader (lambda () (and chunks (pop chunks)))))
      (should (equal (consent-eval-test--external
                      "(import (scheme read)) (read)"
                      (append (list :program-input-reader reader) grants))
                     "(1 2 3 4)")))))

(ert-deftest consent-eval-test-program-output-streams ()
  "Program output/error connect only under a stdout/stderr-backed port grant.
A granted writer receives each write flushed through immediately (write-through,
not buffered to end of program); an ungranted writer fails closed; an unbounded
write loop stays bounded by the host-callback budget; and `current-error-port'
fails closed without a grant.  Parity twin of the portable program-output checks."
  (let ((out-grant '((capability-grant
                      (id program-output) (domain port)
                      (operations write flush close) (scope (backing stdout))
                      (expires never))))
        (err-grant '((capability-grant
                      (id program-error) (domain port)
                      (operations write flush close) (scope (backing stderr))
                      (expires never)))))
    ;; Granted output: each write flushes through, in order.
    (let* ((flushes 0)
           (text "")
           (writer (lambda (chunk)
                     (setq flushes (1+ flushes))
                     (setq text (concat text chunk)))))
      (consent-eval-source
       "(import (scheme write)) (display \"hi\") (newline)" nil
       (list :program-output-writer writer :capability-grants out-grant))
      (should (equal text "hi\n"))
      ;; display and newline flush separately: write-through, not buffer-to-EOF.
      (should (= flushes 2)))
    ;; Ungranted output: a writer offered but no grant -> fails closed.
    (should-error
     (consent-eval-source
      "(import (scheme write)) (display \"x\")" nil
      (list :program-output-writer (lambda (_chunk) nil)))
     :type 'consent-eval-error)
    ;; Unbounded write loop is bounded by the host-callback budget.
    (should-error
     (consent-eval-source
      "(import (scheme base) (scheme write))
       (let loop ((i 0)) (if (< i 50) (progn (display \"y\") (loop (+ i 1)))))" nil
      (list :program-output-writer (lambda (_chunk) nil)
            :max-host-callbacks 5 :capability-grants out-grant))
     :type 'consent-eval-error)
    ;; Granted error port captures via the stderr writer.
    (let* ((text "")
           (writer (lambda (chunk) (setq text (concat text chunk)))))
      (consent-eval-source
       "(write-string \"e!\" (current-error-port))" nil
       (list :program-error-writer writer :capability-grants err-grant))
      (should (equal text "e!")))
    ;; current-error-port fails closed without a grant.
    (should-error
     (consent-eval-source "(current-error-port)" nil nil)
     :type 'consent-eval-error)))

(ert-deftest consent-eval-test-program-binary-input-stream ()
  "Binary program input connects current-input-port under a stdin-backed grant.
A `:program-input-byte-reader' plus an active `port'/`read' grant scoped to
`stdin' lets `read-u8'/`peek-u8'/`read-bytevector' draw bytes from the program
input; without the grant -- or offering a byte reader with no grant -- the read
fails closed exactly as an unconnected current input port does.  Parity twin of
the portable `program-binary-input-read-u8' check."
  (let ((grants '((capability-grant
                   (id program-input)
                   (domain port)
                   (operations read close)
                   (scope (backing stdin))
                   (expires never)))))
    ;; Granted: successive read-u8 advance over the bytes to EOF.
    (should
     (equal
      (consent-eval-test--external
       "(list (read-u8 (current-input-port))
              (read-u8 (current-input-port))
              (eof-object? (read-u8 (current-input-port))))"
       (list :program-input-byte-reader
             (consent-program-input-from-bytevector [104 105])
             :capability-grants grants))
      "(104 105 #t)"))
    ;; peek-u8 does not advance the cursor; read-u8 then returns the peeked byte.
    (should
     (equal
      (consent-eval-test--external
       "(let ((port (current-input-port)))
          (list (peek-u8 port) (read-u8 port) (read-u8 port)))"
       (list :program-input-byte-reader
             (consent-program-input-from-bytevector [7 8])
             :capability-grants grants))
      "(7 7 8)"))
    ;; read-bytevector pulls up to its count across the buffered bytes.
    (should
     (equal
      (consent-eval-test--external
       "(read-bytevector 3 (current-input-port))"
       (list :program-input-byte-reader
             (consent-program-input-from-bytevector [1 2 3 4])
             :capability-grants grants))
      "#u8(1 2 3)"))
    ;; Ungranted: a byte reader offered but no grant -> read fails closed.
    (should-error
     (consent-eval-source
      "(read-u8 (current-input-port))" nil
      (list :program-input-byte-reader
            (consent-program-input-from-bytevector [9])))
     :type 'consent-eval-error)
    ;; Grant present but no byte reader offered -> still disconnected.
    (should-error
     (consent-eval-source
      "(read-u8 (current-input-port))" nil (list :capability-grants grants))
     :type 'consent-eval-error)))

(ert-deftest consent-eval-test-program-binary-input-streaming ()
  "Binary program input is pulled from a host byte reader thunk on demand.
A `:program-input-byte-reader' yields the next bytevector chunk (or nil at end of
stream), so a read consumes only as many bytes as it needs and an unbounded byte
stream never drains up front.  Parity twin of the portable
`program-binary-input-stream-read-u8' checks."
  (let ((grants '(:capability-grants
                  ((capability-grant
                    (id program-input) (domain port) (operations read close)
                    (scope (backing stdin)) (expires never))))))
    ;; Incremental: reading one byte pulls exactly one chunk, not the stream.
    (let* ((pulls 0)
           (chunks (list [10] [20] [30]))
           (reader (lambda ()
                     (setq pulls (1+ pulls))
                     (and chunks (pop chunks)))))
      (should (equal (consent-eval-test--external
                      "(read-u8 (current-input-port))"
                      (append (list :program-input-byte-reader reader) grants))
                     "10"))
      (should (= pulls 1)))
    ;; An unbounded reader would hang here if the port drained eagerly; reading a
    ;; bounded number of bytes completes because refills stop once a byte buffers.
    (should (equal (consent-eval-test--external
                    "(let ((port (current-input-port)))
                       (list (read-u8 port) (read-u8 port) (read-u8 port)))"
                    (append (list :program-input-byte-reader (lambda () [120]))
                            grants))
                   "(120 120 120)"))
    ;; A read-bytevector spanning multiple chunks refills until count bytes buffer.
    (let* ((chunks (list [1 2] [3] [4 5]))
           (reader (lambda () (and chunks (pop chunks)))))
      (should (equal (consent-eval-test--external
                      "(read-bytevector 4 (current-input-port))"
                      (append (list :program-input-byte-reader reader) grants))
                     "#u8(1 2 3 4)")))))

(ert-deftest consent-eval-test-program-binary-output-streams ()
  "Binary program output/error connect only under a stdout/stderr-backed grant.
A granted byte writer receives each write flushed through immediately
(write-through, not buffered to end of program); an ungranted writer fails closed;
an unbounded write loop stays bounded by the host-callback budget.  Parity twin of
the portable binary program-output checks."
  (let ((out-grant '((capability-grant
                      (id program-output) (domain port)
                      (operations write flush close) (scope (backing stdout))
                      (expires never))))
        (err-grant '((capability-grant
                      (id program-error) (domain port)
                      (operations write flush close) (scope (backing stderr))
                      (expires never)))))
    ;; Granted output: each byte write flushes through, in order.
    (let* ((flushes 0)
           (bytes nil)
           (writer (lambda (chunk)
                     (setq flushes (1+ flushes))
                     (setq bytes (append bytes chunk)))))
      (consent-eval-source
       "(let ((port (current-output-port)))
          (write-u8 104 port)
          (write-bytevector #u8(105 33) port))" nil
       (list :program-output-byte-writer writer :capability-grants out-grant))
      (should (equal bytes '(104 105 33)))
      ;; write-u8 and write-bytevector flush separately: write-through.
      (should (= flushes 2)))
    ;; Ungranted output: a byte writer offered but no grant -> fails closed.
    (should-error
     (consent-eval-source
      "(write-u8 120 (current-output-port))" nil
      (list :program-output-byte-writer (lambda (_chunk) nil)))
     :type 'consent-eval-error)
    ;; Unbounded write loop is bounded by the host-callback budget.
    (should-error
     (consent-eval-source
      "(let loop ((i 0))
         (if (< i 50)
             (progn (write-u8 121 (current-output-port)) (loop (+ i 1)))))" nil
      (list :program-output-byte-writer (lambda (_chunk) nil)
            :max-host-callbacks 5 :capability-grants out-grant))
     :type 'consent-eval-error)
    ;; Granted error port captures via the stderr byte writer.
    (let* ((bytes nil)
           (writer (lambda (chunk) (setq bytes (append bytes chunk)))))
      (consent-eval-source
       "(write-u8 33 (current-error-port))" nil
       (list :program-error-byte-writer writer :capability-grants err-grant))
      (should (equal bytes '(33))))))

(ert-deftest consent-eval-test-let-empty-bindings-and-char-literals ()
  "Evaluate `let' with empty bindings and delimiter character literals.
Regression: the syntax-rules matcher must match ((name val) ...) against ();
the reader must read #\\( #\\| etc. literally; char->integer must yield a number."
  (should (equal (consent-eval-test--external "(let () 5)") "5"))
  (should (equal (consent-eval-test--external
                  "(let () (define x 6) (* x 7))")
                 "42"))
  (should (equal (consent-eval-test--external "(char->integer #\\()") "40"))
  (should (equal (consent-eval-test--external "(char->integer #\\|)") "124"))
  (should (equal (consent-eval-test--external "(+ 1 (char->integer #\\a))") "98")))

(ert-deftest consent-eval-test-variables-definitions-and-calls ()
  "Evaluate top-level definitions, variable references, and calls."
  (should
   (equal (consent-eval-test--external
           "(define answer 40)
            (+ answer 2)")
          "42"))
  (should
   (equal (consent-eval-test--external
           "(begin
              (define answer 42)
              answer)")
          "42"))
  (should
   (equal (consent-eval-test--external "((if #f + *) 3 4)")
          "12"))
  (should-error (consent-eval-source "missing")
                :type 'consent-eval-error)
  (should-error (consent-eval-source "(missing 1)")
                :type 'consent-eval-error)
  (should-error (consent-eval-source "(1 2)")
                :type 'consent-eval-error))

(ert-deftest consent-eval-test-definition-shadows-parent-frames ()
  "Define new names in the current frame without mutating parents."
  (let* ((parent (consent-make-base-environment))
         (child (consent-make-empty-environment parent)))
    (should
     (equal (consent-value->external
             (consent-eval-source
              "(define (+ x y)
                 y)
               (+ 1 2)"
              child))
            "2"))
    (should
     (equal (consent-value->external
             (consent-eval-source "(+ 1 2)" parent))
            "3"))))

(ert-deftest consent-eval-test-lexical-closures-and-internal-definitions ()
  "Evaluate closures with lexical scope and internal definitions."
  (should
   (equal (consent-eval-test--external
           "(define (make-adder x)
              (lambda (y) (+ x y)))
            ((make-adder 4) 6)")
          "10"))
  (should
   (equal (consent-eval-test--external
           "((lambda (x)
               (define y 2)
               (+ x y))
             3)")
          "5"))
  (should
   (equal (consent-eval-test--external
           "((lambda (x)
               (define (twice y) (+ y y))
               (twice x))
             5)")
          "10"))
  (should
   (equal (consent-eval-test--external
           "((lambda ()
               (define (+ x y)
                 x)
               (+ 1 2)))")
          "1")))

(ert-deftest consent-eval-test-set-mutates-lexical-locations ()
  "Evaluate set! against lexical and captured locations."
  (should
   (equal (consent-eval-test--external
           "((lambda (x)
               (set! x (+ x 1))
               x)
             2)")
          "3"))
  (should
   (equal (consent-eval-test--external
           "(define (make-counter)
              (define x 0)
              (lambda ()
                (set! x (+ x 1))
                x))
            (define counter (make-counter))
            (counter)
            (counter)")
          "2"))
  (should-error (consent-eval-source "(set! missing 1)")
                :type 'consent-eval-error))

(ert-deftest consent-eval-test-if-uses-scheme-truthiness ()
  "Evaluate if with only #f as false."
  (should (equal (consent-eval-test--external "(if #f 1 2)") "2"))
  (should (equal (consent-eval-test--external "(if '() 1 2)") "1"))
  (should
   (equal (consent-eval-test--external "(if #f 1)")
          "#<unspecified>")))

(ert-deftest consent-eval-test-lambda-formals ()
  "Evaluate fixed, variadic, and dotted lambda formals."
  (should
   (equal (consent-eval-test--external "((lambda x x) 3 4 5)")
          "(3 4 5)"))
  (should
   (equal (consent-eval-test--external "((lambda (x y . z) z) 3 4 5 6)")
          "(5 6)"))
  (should-error (consent-eval-source "((lambda (x x) x) 1 2)")
                :type 'consent-eval-error)
  (should-error (consent-eval-source "((lambda (x) x) 1 2)")
                :type 'consent-eval-error))

(ert-deftest consent-eval-test-tail-recursive-loop-uses-trampoline ()
  "Run a tail-recursive loop beyond a shallow host recursion shape."
  (should
   (equal (consent-eval-test--external
           "(define (loop n acc)
              (if (= n 0)
                  acc
                (loop (- n 1) (+ acc 1))))
            (loop 5000 0)"
           '(:max-steps 100000
             :max-host-callbacks 30000))
          "5000")))

(ert-deftest consent-eval-test-budgets-fail-closed ()
  "Interrupt evaluations that exceed configured budgets."
  (should-error
   (consent-eval-source
    "(define (loop n) (loop n))
     (loop 0)"
    nil
    '(:max-steps 40))
   :type 'consent-budget-error)
  (should-error
   (consent-eval-source "'(1 2 3)" nil '(:max-value-nodes 2))
   :type 'consent-budget-error)
  (should-error
   (consent-eval-source "(+ 1 2)" nil '(:max-host-callbacks 0))
   :type 'consent-budget-error))

(ert-deftest consent-eval-test-multiple-values-and-binding-forms ()
  "Evaluate values, call-with-values, define-values, and binding forms."
  (should
   (string-match-p
    (regexp-quote
     "(evaluation-result (status values) (values (1 2))")
    (consent-eval-test--result-external "(values 1 2)")))
  (should
   (equal (consent-eval-test--external
           "(call-with-values (lambda () (values 4 5))
                              (lambda (a b) (- b a)))")
          "1"))
  (should
   (equal (consent-eval-test--external
           "(let-values (((a b) (values 1 2))
                         ((rest) (values '(x y))))
              (list a b rest))")
          "(1 2 (x y))"))
  (should
   (equal (consent-eval-test--external
           "(let ((a 'a) (b 'b) (x 'x) (y 'y))
              (let*-values (((a b) (values x y))
                            ((x y) (values a b)))
                (list a b x y)))")
          "(x y x y)"))
  (should
   (equal (consent-eval-test--external
           "(define-values (root remainder)
              (exact-integer-sqrt 17))
            (define-values (head . tail)
              (values 'a 'b 'c))
            (define-values all
              (values 8 13))
            (list root remainder (cons head tail) all)")
          "(4 1 (a b c) (8 13))"))
  (should
   (equal (consent-eval-test--external
           "((lambda ()
               (define-values (left right)
                 (values 8 13))
               (list left right)))")
          "(8 13)")))

(ert-deftest consent-eval-test-continuations-and-dynamic-wind ()
  "Evaluate re-enterable continuations and dynamic-wind transitions."
  (should
   (equal (consent-eval-test--external
           "(call/cc (lambda (escape) (+ 1 (escape 42))))")
          "42"))
  (should
   (equal (consent-eval-test--external
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
              (reverse path))")
          "(before during after)"))
  (should
   (equal (consent-eval-test--external
           "(let ((again #f))
              (let ((value (call/cc
                            (lambda (k)
                              (set! again k)
                              'first))))
                (if (eq? value 'first)
                    (again 'second)
                  value)))")
          "second"))
  (should
   (equal (consent-eval-test--external
           "(let ((again #f)
                  (seen '()))
              (let ((value (call/cc
                            (lambda (k)
                              (set! again k)
                              'start))))
                (set! seen (cons value seen))
                (if (< (length seen) 3)
                    (again (length seen))
                  (reverse seen))))")
          "(start 1 2)"))
  (should
   (equal (consent-eval-test--external
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
                (reverse path)))")
          "(before-outer before-inner during-inner after-inner after-outer before-outer before-inner during-inner after-inner after-outer)"))
  (should
   (equal (consent-eval-test--external
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
                   (list a b)))))")
          "(3 4)"))
  (should
   (equal (consent-eval-test--external
           "(let ((again #f))
              (let-values (((a b)
                            (call/cc
                             (lambda (k)
                               (set! again k)
                               (values 1 2)))))
                (if (= a 1)
                    (again 3 4)
                  (list a b))))")
          "(3 4)"))
  (should
   (equal (consent-eval-test--external
           "(let ((again #f))
              (let*-values (((a b)
                             (call/cc
                              (lambda (k)
                                (set! again k)
                                (values 1 2))))
                            ((c) (+ a b)))
                (if (= a 1)
                    (again 3 4)
                  (list a b c))))")
          "(3 4 7)")))

(ert-deftest consent-eval-test-exceptions-and-guard ()
  "Evaluate R7RS exception handlers, guard, continuable raises, and error."
  (should
   (equal (consent-eval-test--external
           "(guard (exn (else (list 'caught exn)))
              (raise 'boom))")
          "(caught boom)"))
  (should
   (equal (consent-eval-test--external
           "(with-exception-handler
              (lambda (exn) 42)
              (lambda ()
                (+ (raise-continuable 'warning) 23)))")
          "65"))
  (should
   (equal (consent-eval-test--external
           "(guard (exn
                    ((error-object? exn)
                     (list (error-object-message exn)
                           (error-object-irritants exn))))
              (error \"bad input\" 'alpha 7))")
          "(\"bad input\" (alpha 7))")))

(defun consent-eval-test--fresh-context (&optional options)
  "Return a cons of a fresh evaluation context and base environment.
OPTIONS is an evaluation-context option plist (e.g. `:max-steps')."
  (let ((context (consent--new-eval-context options))
        (environment (consent-make-base-environment)))
    (setf (consent--eval-context-interaction-environment context)
          environment)
    (consent--ensure-base-syntax context environment)
    (cons context environment)))

(defun consent-eval-test--run-on (source context environment)
  "Evaluate SOURCE through the CPS trampoline on CONTEXT and ENVIRONMENT."
  (consent--trampoline
   (consent--make-sequence (consent-read-all source nil) t)
   environment
   context))

(ert-deftest consent-eval-test-exception-handler-unwind-safe ()
  "A handler that re-raises non-continuably restores handler state.
Whether the exception machinery runs through the CPS trampoline or the
direct (non-`/k') primitive, an Emacs Lisp `signal' escaping the invoked
handler must leave `exception-handlers' and `current-error' at their
pre-evaluation baseline.  Regression for the CPS path that previously
restored that state only inside its success continuation."
  ;; CPS path: the inner handler re-raises non-continuably; the outer
  ;; handler returns, which signals "non-continuable exception handler
  ;; returned" before any success continuation can pop the installed
  ;; frames.
  (let* ((cell (consent-eval-test--fresh-context))
         (context (car cell))
         (environment (cdr cell))
         (baseline-handlers
          (consent--eval-context-exception-handlers context))
         (baseline-error
          (consent--eval-context-current-error context)))
    (should-error
     (consent-eval-test--run-on
      "(with-exception-handler
         (lambda (outer) 'outer-returned)
         (lambda ()
           (with-exception-handler
            (lambda (inner) (raise 'from-inner))
            (lambda () (raise 'original)))))"
      context environment)
     :type 'consent-eval-error)
    (should (equal (consent--eval-context-exception-handlers context)
                   baseline-handlers))
    (should (eq (consent--eval-context-current-error context)
                baseline-error)))
  ;; Direct path: enter through the non-`/k' `with-exception-handler'
  ;; primitive with the same nested scenario built as procedures.
  (let* ((cell (consent-eval-test--fresh-context))
         (context (car cell))
         (environment (cdr cell))
         (handler
          (consent-eval-test--run-on
           "(lambda (outer) 'outer-returned)" context environment))
         (thunk
          (consent-eval-test--run-on
           "(lambda ()
              (with-exception-handler
               (lambda (inner) (raise 'from-inner))
               (lambda () (raise 'original))))"
           context environment))
         (baseline-handlers
          (consent--eval-context-exception-handlers context))
         (baseline-error
          (consent--eval-context-current-error context)))
    (should-error
     (consent--primitive-with-exception-handler
      (list handler thunk) context)
     :type 'consent-eval-error)
    (should (equal (consent--eval-context-exception-handlers context)
                   baseline-handlers))
    (should (eq (consent--eval-context-current-error context)
                baseline-error))))

(ert-deftest consent-eval-test-current-error-restored-after-escape ()
  "Escaping a handler resets `current-error' to its capture-time value.
A continuation escape (`guard' or `call/cc') reinstates the dynamic state
snapshotted with the continuation, so `current-error' must not leak the
handled condition past the escape -- the continuation-escape companion to
the CPS handler-stack unwind-safety guarantee.  A live, non-escaping
handler must still observe the condition so the debugger inspection path
keeps working."
  ;; A guard escape clears the handled condition afterward.
  (should
   (equal (consent-eval-test--external
           "(import (scheme base) (agent debugger))
            (guard (exn (else 'caught)) (raise 'boom))
            (current-error)")
          "#f"))
  ;; A call/cc escape out of a handler clears it too.
  (should
   (equal (consent-eval-test--external
           "(import (scheme base) (agent debugger))
            (call/cc
             (lambda (k)
               (with-exception-handler
                (lambda (condition) (k 'escaped))
                (lambda () (raise 'boom)))))
            (current-error)")
          "#f"))
  ;; A non-escaping handler still observes the live condition.
  (should
   (equal (consent-eval-test--external
           "(import (scheme base) (agent debugger))
            (with-exception-handler
             (lambda (condition)
               (if (current-error) 'sees-condition 'blank))
             (lambda () (raise-continuable 'boom)))")
          "sees-condition")))

(ert-deftest consent-eval-test-dynamic-wind-after-runs-on-raise ()
  "A `dynamic-wind' after thunk runs when a raise unwinds to an outer guard.
Companion to the call/cc-escape dynamic-wind coverage: an exception escape
must run pending after thunks while unwinding to the handler."
  (should
   (equal (consent-eval-test--external
           "(let ((log '()))
              (define (add tag) (set! log (cons tag log)))
              (guard (exn (else (add 'caught) (reverse log)))
                (dynamic-wind
                 (lambda () (add 'before))
                 (lambda () (add 'during) (raise 'x))
                 (lambda () (add 'after)))))")
          "(before during after caught)")))

(ert-deftest consent-eval-test-budget-error-in-handler-unwind-safe ()
  "A budget overflow raised while a handler runs restores dynamic state.
The checkpoint must cover Emacs Lisp `signal's beyond raises: a step
budget exceeded inside an invoked handler still leaves `exception-handlers'
and `current-error' at their pre-evaluation baseline."
  (let* ((cell (consent-eval-test--fresh-context '(:max-steps 5000)))
         (context (car cell))
         (environment (cdr cell))
         (baseline-handlers
          (consent--eval-context-exception-handlers context))
         (baseline-error
          (consent--eval-context-current-error context)))
    (should-error
     (consent-eval-test--run-on
      "(define (spin n) (spin (+ n 1)))
       (with-exception-handler
        (lambda (condition) (spin 0))
        (lambda () (raise 'boom)))"
      context environment)
     :type 'consent-budget-error)
    (should (equal (consent--eval-context-exception-handlers context)
                   baseline-handlers))
    (should (eq (consent--eval-context-current-error context)
                baseline-error))))

(ert-deftest consent-eval-test-dynamic-wind-stack-unwind-safe ()
  "An aborting signal does not leak `dynamic-wind' frames onto the context.
When an unhandled raise unwinds the trampoline out of a `dynamic-wind'
body, the context's dynamic-wind stack must return to its pre-evaluation
baseline rather than retaining the entered frame."
  (let* ((cell (consent-eval-test--fresh-context))
         (context (car cell))
         (environment (cdr cell))
         (baseline-winds
          (consent--eval-context-dynamic-winds context)))
    (should-error
     (consent-eval-test--run-on
      "(dynamic-wind
         (lambda () 'before)
         (lambda () (raise 'boom))
         (lambda () 'after))"
      context environment)
     :type 'consent-eval-error)
    (should (equal (consent--eval-context-dynamic-winds context)
                   baseline-winds))))

(ert-deftest consent-eval-test-reentrant-continuation-restores-current-error ()
  "Re-invoking a continuation captured inside a handler restores `current-error'.
A continuation snapshots the dynamic state at capture time, so re-entering
a handler must reinstate that handler's condition -- not whatever condition
is current at the point of re-invocation.  The probe captures a continuation
while handling `FIRST', handles an unrelated `SECOND' in between, then
re-enters: `current-error' must report `FIRST' on both passes, proving the
snapshot is restored rather than the ambient (or stale) condition leaking in."
  (should
   (equal (consent-eval-test--external
           "(import (scheme base) (agent debugger))
            (define k #f)
            (define seen '())
            (define (err-value)
              (let ((condition (current-error)))
                (if condition (cadr (assq 'value (cdr condition))) 'none)))
            (guard (top (#t 'done-first))
              (with-exception-handler
               (lambda (condition)
                 (call/cc (lambda (cc) (set! k cc)))
                 (set! seen (cons (err-value) seen))
                 (raise 'leave-first))
               (lambda () (raise-continuable 'FIRST))))
            (guard (other (#t 'done-second)) (raise 'SECOND))
            (if k (let ((resume k)) (set! k #f) (resume 'reenter)))
            (reverse seen)")
          "(\"FIRST\" \"FIRST\")")))

;;; consent-eval-test.el ends here
