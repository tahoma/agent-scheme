;;; Dynamically bindable current-port tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This shared program exercises direct R7RS hosts and both compiled Consent
;;; self-host runners so current-port parameter behavior stays host-neutral.

(import (scheme base)
        (scheme process-context)
        (scheme write)
        (testing registry)
        (testing runner)
        (stdlib testing))

(testing-registry-case
 'current-ports-bind-and-restore '(portable core ports)
 (let ((default-input (current-input-port))
       (default-output (current-output-port))
       (default-error (current-error-port))
       (input (open-input-string "i"))
       (output (open-output-string))
       (error-port (open-output-string)))
   (let ((inside
          (parameterize ((current-input-port input)
                         (current-output-port output)
                         (current-error-port error-port))
            (write-string "out")
            (write-string "err" (current-error-port))
            (list (read-char)
                  (eq? (current-input-port) input)
                  (eq? (current-output-port) output)
                  (eq? (current-error-port) error-port)))))
     (test-equal 'current-ports-bound
                 '(#\i #t #t #t)
                 inside)
     (test-equal 'current-ports-write-targets
                 '("out" "err")
                 (list (get-output-string output)
                       (get-output-string error-port)))
     (test-equal 'current-ports-restored
                 '(#t #t #t)
                 (list (eq? (current-input-port) default-input)
                       (eq? (current-output-port) default-output)
                       (eq? (current-error-port) default-error))))))

(testing-registry-case
 'current-ports-nest '(portable core ports)
 (let ((outer-input (open-input-string "ab"))
       (inner-input (open-input-string "z"))
       (outer-output (open-output-string))
       (inner-output (open-output-string))
       (outer-error (open-output-string))
       (inner-error (open-output-string)))
   (let ((characters
          (parameterize ((current-input-port outer-input)
                         (current-output-port outer-output)
                         (current-error-port outer-error))
            (write-string "a")
            (write-string "x" (current-error-port))
            (let ((first (read-char)))
              (let ((middle
                     (parameterize ((current-input-port inner-input)
                                    (current-output-port inner-output)
                                    (current-error-port inner-error))
                       (write-string "b")
                       (write-string "y" (current-error-port))
                       (read-char))))
                (write-string "c")
                (write-string "z" (current-error-port))
                (list first middle (read-char)))))))
     (test-equal 'current-input-port-nesting '(#\a #\z #\b) characters)
     (test-equal 'current-output-port-nesting
                 '("ac" "b")
                 (list (get-output-string outer-output)
                       (get-output-string inner-output)))
     (test-equal 'current-error-port-nesting
                 '("xz" "y")
                 (list (get-output-string outer-error)
                       (get-output-string inner-error))))))

(testing-registry-case
 'current-ports-restore-after-exception '(portable core ports)
 (let ((default-input (current-input-port))
       (default-output (current-output-port))
       (default-error (current-error-port)))
   (guard (condition
           (else
            (test-equal
             'current-ports-restored-after-exception
             '(#t #t #t)
             (list (eq? (current-input-port) default-input)
                   (eq? (current-output-port) default-output)
                   (eq? (current-error-port) default-error)))))
     (parameterize ((current-input-port (open-input-string ""))
                    (current-output-port (open-output-string))
                    (current-error-port (open-output-string)))
       (raise 'current-port-test-exception)))))

(testing-registry-case
 'current-ports-follow-continuations '(portable core ports)
 (let ((default-output (current-output-port))
       (bound-output (open-output-string))
       (again #f)
       (outside #f)
       (observed '()))
   (call/cc
    (lambda (escape)
      (set! outside escape)
      (parameterize ((current-output-port bound-output))
        (call/cc (lambda (continuation) (set! again continuation)))
        (set! observed
              (cons (eq? (current-output-port) bound-output) observed))
        (outside 'escaped))))
   (set! observed
         (cons (eq? (current-output-port) default-output) observed))
   (if again
       (let ((resume again))
         (set! again #f)
         (resume 'resumed))
       (test-equal 'current-ports-follow-continuations
                   '(#t #t #t #t)
                   (reverse observed)))))

(testing-runner-main "Dynamically bindable current ports" (command-line))
