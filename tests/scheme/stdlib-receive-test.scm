;;; Portable SRFI 8 receive stdlib tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (stdlib receive)
        (scheme process-context)
        (testing registry)
        (testing runner)
        (stdlib testing))

(testing-registry-case
 'fixed-formals '(portable stdlib)
(test-equal 'fixed-formals
             7
             (receive (x y) (values 2 5)
         (+ x y))))

(testing-registry-case
 'rest-formals '(portable stdlib)
(test-equal 'rest-formals
             '(a b c)
             (receive all (values 'a 'b 'c)
         all)))

(testing-registry-case
 'dotted-formals '(portable stdlib)
(test-equal 'dotted-formals
             '(first (second third))
             (receive (head . tail) (values 'first 'second 'third)
         (list head tail))))

(testing-registry-case
 'body-sequence '(portable stdlib)
(test-equal 'body-sequence
             28
             (receive (x y) (values 3 4)
         (define sum (+ x y))
         (* sum y))))

(testing-runner-main "Stdlib Receive portable tests" (command-line))
