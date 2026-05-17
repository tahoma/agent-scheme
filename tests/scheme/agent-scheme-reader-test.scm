(import (scheme base)
        (scheme write)
        (agent-scheme reader))

(define failures 0)

(define (record-failure name expected actual)
  (set! failures (+ failures 1))
  (display "FAIL ")
  (write name)
  (display ": expected ")
  (write expected)
  (display ", got ")
  (write actual)
  (newline))

(define (check name actual expected)
  (if (not (equal? actual expected))
      (record-failure name expected actual)))

(define (check-external name source expected)
  (check name
         (agent-scheme-datum->external (agent-scheme-read source))
         expected))

(define (raises? thunk)
  (guard (condition
          (else #t))
    (thunk)
    #f))

(check-external 'boolean-true "#true" "#t")
(check-external 'boolean-false "#false" "#f")
(check 'false-is-not-null (null? (agent-scheme-read "#f")) #f)
(check 'empty-list-is-null (null? (agent-scheme-read "()")) #t)

(check-external 'symbol-case "Agent-Scheme" "Agent-Scheme")
(check-external 'fold-case "#!fold-case Agent-Scheme" "agent-scheme")
(check-external 'vertical-symbol "|two\\x20;words|" "|two words|")

(check 'string-escapes
       (agent-scheme-read "\"line\\n\\x03bb;\"")
       (string-append "line\n" (string (integer->char #x03bb))))
(check 'string-line-continuation
       (agent-scheme-read (string-append "\"a\\" "\n  b\""))
       "ab")
(check-external 'character-name "#\\space" "#\\space")
(check-external 'character-hex "#\\X03BB" "#\\λ")

(define character-writer-cases
  '(("character-writer-space" "#\\space" "#\\space")
    ("character-writer-tab" "#\\tab" "#\\tab")
    ("character-writer-alarm" "#\\alarm" "#\\alarm")
    ("character-writer-backspace" "#\\backspace" "#\\backspace")
    ("character-writer-delete-name" "#\\delete" "#\\delete")
    ("character-writer-escape" "#\\escape" "#\\escape")
    ("character-writer-newline" "#\\newline" "#\\newline")
    ("character-writer-null" "#\\null" "#\\null")
    ("character-writer-return" "#\\return" "#\\return")
    ("character-writer-printable" "#\\a" "#\\a")
    ("character-writer-unicode" "#\\x03bb" "#\\λ")
    ("character-writer-control-start-of-heading" "#\\x1" "#\\x1")
    ("character-writer-control-unit-separator" "#\\x1f" "#\\x1f")
    ("character-writer-delete" "#\\x7f" "#\\delete")))

(for-each
 (lambda (case)
   (let* ((name (string->symbol (car case)))
          (source (cadr case))
          (expected (list-ref case 2))
          (external (agent-scheme-datum->external
                     (agent-scheme-read source))))
     (check name external expected)
     (check (string->symbol (string-append (car case) "-round-trip"))
            (agent-scheme-datum->external
             (agent-scheme-read external))
            expected)))
 character-writer-cases)

(check-external 'integer "42" "42")
(check 'integer-is-agent-owned
       (number? (agent-scheme-read "42"))
       #f)
(check-external 'hex-integer "#x2a" "42")
(check-external 'rational "3/4" "3/4")
(check-external 'decimal "1.5" "1.5")
(check-external 'reduced-rational "6/10" "3/5")
(check-external 'exact-decimal "#e1.5" "3/2")
(check-external 'inexact-rational "#i3/2" "1.5")
(check-external 'complex-rectangular "3/4-5/6i" "3/4-5/6i")
(check-external 'infinity "+inf.0" "+inf.0")
(check-external 'complex-positive-infinity-imaginary "+inf.0i" "0+inf.0i")
(check-external 'complex-negative-infinity-imaginary "-inf.0i" "0-inf.0i")
(check-external 'complex-nan-imaginary "+nan.0i" "0+nan.0i")
(check-external 'polar-infinite-magnitude "+inf.0@0" "+inf.0+nan.0i")
(check-external 'polar-infinite-angle "1@+inf.0" "+nan.0+nan.0i")
(check-external 'polar-nan-magnitude "+nan.0@0" "+nan.0+nan.0i")
(check-external 'bare-i-symbol "i" "i")

(check-external 'dotted-list "(alpha beta . gamma)" "(alpha beta . gamma)")
(check-external 'quote "'alpha" "(quote alpha)")
(check-external
 'quasiquote
 "`(,alpha ,@beta)"
 "(quasiquote ((unquote alpha) (unquote-splicing beta)))")
(check-external 'vector "#(1 alpha \"ok\")" "#(1 alpha \"ok\")")
(check-external 'bytevector "#u8(0 127 255)" "#u8(0 127 255)")

(check 'comments
       (map agent-scheme-datum->external
            (agent-scheme-read-all
             "; ignore\n#| nested #| comment |# done |#\n1 #;(skip me) 2"))
       '("1" "2"))

(check 'list-limit
       (raises?
        (lambda ()
          (agent-scheme-read "(1 2 3)" '((max-list-length . 2)))))
       #t)
(check 'vector-limit
       (raises?
        (lambda ()
          (agent-scheme-read "#(1 2 3)" '((max-vector-length . 2)))))
       #t)
(let ((circular (agent-scheme-read "#1=(a . #1#)"))
      (shared (agent-scheme-read "(#1=(a b) #1#)")))
  (check 'datum-labels-circular-identity
         (eq? circular (cdr circular))
         #t)
  (check 'datum-labels-shared-identity
         (eq? (car shared) (cadr shared))
         #t)
  (check 'datum-labels-circular-writer
         (agent-scheme-datum->external circular)
         "#0=(a . #0#)")
  (check 'datum-labels-shared-simple-writer
         (agent-scheme-datum->external shared)
         "((a b) (a b))"))

(if (= failures 0)
    (begin
      (display "Scheme reader tests passed")
      (newline))
    (begin
      (display failures)
      (display " Scheme reader test failure(s)")
      (newline)
      (error "Scheme reader tests failed")))
