;;; Portable redaction string-scanning kernel.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This internal library owns only the stateless byte-for-byte predicate used
;;; by the source-backed redaction policy. It cannot log, retain input, invoke
;;; callbacks, or decide how a matching string is represented or disclosed.

(define-library (agent redaction-kernel)
  (export redaction-kernel-secret-string?)
  (import (scheme base))
  (begin
    (define (redaction-kernel-start-state character)
      "Return the single-character prefix state for CHARACTER."
      (cond
       ((char=? character #\s) 's)
       ((char=? character #\g) 'g)
       ((char=? character #\x) 'x)
       ((char=? character #\A) 'upper-a)
       ((char=? character #\P) 'private-p)
       (else 'empty)))

    (define (redaction-kernel-next-state state character)
      "Advance the fixed secret-prefix automaton with CHARACTER."
      (case state
        ((empty)
         (redaction-kernel-start-state character))
        ((s)
         (if (char=? character #\k)
             'sk
             (redaction-kernel-start-state character)))
        ((sk)
         (if (char=? character #\-)
             'match
             (redaction-kernel-start-state character)))
        ((g)
         (if (char=? character #\h)
             'gh
             (redaction-kernel-start-state character)))
        ((gh)
         (cond
          ((char=? character #\p) 'ghp)
          ((char=? character #\o) 'gho)
          ((char=? character #\u) 'ghu)
          ((char=? character #\s) 'ghs)
          ((char=? character #\r) 'ghr)
          (else (redaction-kernel-start-state character))))
        ((ghp gho ghu ghr)
         (if (char=? character #\_)
             'match
             (redaction-kernel-start-state character)))
        ((ghs)
         (cond
          ((char=? character #\_) 'match)
          ;; The failed `ghs_` candidate leaves `sk` as a live suffix.
          ((char=? character #\k) 'sk)
          (else (redaction-kernel-start-state character))))
        ((x)
         (if (char=? character #\o)
             'xo
             (redaction-kernel-start-state character)))
        ((xo)
         (if (char=? character #\x)
             'match
             (redaction-kernel-start-state character)))
        ((upper-a)
         (if (char=? character #\K)
             'akia-k
             (redaction-kernel-start-state character)))
        ((akia-k)
         (if (char=? character #\I)
             'akia-ki
             (redaction-kernel-start-state character)))
        ((akia-ki)
         (if (char=? character #\A)
             'match
             (redaction-kernel-start-state character)))
        ((private-p)
         (if (char=? character #\R)
             'private-pr
             (redaction-kernel-start-state character)))
        ((private-pr)
         (if (char=? character #\I)
             'private-pri
             (redaction-kernel-start-state character)))
        ((private-pri)
         (if (char=? character #\V)
             'private-priv
             (redaction-kernel-start-state character)))
        ((private-priv)
         (if (char=? character #\A)
             'private-priva
             (redaction-kernel-start-state character)))
        ((private-priva)
         (cond
          ((char=? character #\T) 'private-privat)
          ;; The failed `PRIVATE KEY` candidate leaves `AK` as a live suffix.
          ((char=? character #\K) 'akia-k)
          (else (redaction-kernel-start-state character))))
        ((private-privat)
         (if (char=? character #\E)
             'private-private
             (redaction-kernel-start-state character)))
        ((private-private)
         (if (char=? character #\space)
             'private-space
             (redaction-kernel-start-state character)))
        ((private-space)
         (if (char=? character #\K)
             'private-space-k
             (redaction-kernel-start-state character)))
        ((private-space-k)
         (if (char=? character #\E)
             'private-space-ke
             (redaction-kernel-start-state character)))
        ((private-space-ke)
         (if (char=? character #\Y)
             'match
             (redaction-kernel-start-state character)))
        (else
         (error "unknown redaction string scanner state" state))))

    (define (redaction-kernel-secret-string? text)
      "Return #t when TEXT contains a recognized secret spelling."
      #((parameters
         (text (type string)
          (description "Diagnostic text to inspect without retaining.")))
        (returns (type boolean)
         (description "#t when TEXT contains a recognized secret spelling."))
        (effects pure))
      ;; R7RS permits variable-width strings whose indexed access is not O(1).
      ;; Keep one automaton state and consume the host string exactly once.
      (call-with-current-continuation
       (lambda (return)
         (let ((state 'empty))
           (string-for-each
            (lambda (character)
              (let ((next-state
                     (redaction-kernel-next-state state character)))
                (if (eq? next-state 'match)
                    (return #t)
                    (set! state next-state))))
            text)
           #f))))))
