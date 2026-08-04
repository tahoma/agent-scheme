;;; SRFI 78 lightweight testing support for stdlib.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2005-2006 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Vendored from the official SRFI 78 reference implementation at
;;; <https://srfi.schemers.org/srfi-78/check.scm>, final SRFI text plus
;;; source snapshot SHA-256
;;; ade1da44903e9208d906dbccd3bf2935b72cfea9dafc2d4db2ef6d0a5712568a.
;;; Local patches wrap the implementation in an R7RS define-library form,
;;; import R7RS `(scheme cxr)' / `(scheme write)' support plus SRFI 42
;;; eager-comprehensions through `(stdlib eager-comprehensions)', add Consent
;;; Scheme docstring metadata, use a call/cc early exit for `check-ec' to
;;; avoid host-sensitive `first-ec' expansion bugs, and expose
;;; `(srfi 78)', `(srfi srfi-78)', `(srfi :78)', and
;;; `(srfi :78 lightweight-testing)' as manifest aliases.

(define-library (stdlib lightweight-testing)
  (export
   check
   check-ec
   check-report
   check-set-mode!
   check-reset!
   check-passed?)
  ;; Gambit expands imported syntax-rules templates in the client library
  ;; environment and requires helper identifiers referenced by those templates
  ;; to be exported. Keep that host accommodation out of the manifest and other
  ;; R7RS hosts.
  (cond-expand
   (gambit
    (export
     check:write
     check:mode
     check:correct
     check:failed
     check:add-correct!
     check:add-failed!
     check:report-expression
     check:report-actual-result
     check:report-correct
     check:report-failed
     check:proc
     check:proc-ec
     check-ec:make))
   (else))
  (import (scheme base)
          (scheme cxr)
          (scheme write)
          (stdlib eager-comprehensions))
  (begin
    ;; Writer used for human-readable check reports.
    (define check:write write)

    ;; Current reporting mode encoded as an upstream-compatible integer.
    (define check:mode #f)

    (define (check-set-mode! mode)
      "Set the SRFI 78 reporting mode to MODE."
      #((parameters
         (mode (type symbol)
          (description "One of off, summary, report-failed, or report.")))
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write error))
      (set! check:mode
            (case mode
              ((off) 0)
              ((summary) 1)
              ((report-failed) 10)
              ((report) 100)
              (else (error "unrecognized mode" mode)))))

    (check-set-mode! 'report)

    ;; Number of correct checks recorded in the current global SRFI 78 state.
    (define check:correct #f)

    ;; Failed checks recorded newest-first in the current global SRFI 78 state.
    (define check:failed #f)

    (define (check-reset!)
      "Reset the SRFI 78 global check counters and first-failure state."
      #((parameters)
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-write))
      (set! check:correct 0)
      (set! check:failed '()))

    (define (check:add-correct!)
      "Record one correct SRFI 78 check."
      (set! check:correct (+ check:correct 1)))

    (define (check:add-failed! expression actual-result expected-result)
      "Record one failed SRFI 78 check."
      (set! check:failed
            (cons (list expression actual-result expected-result)
                  check:failed)))

    (check-reset!)

    (define (check:report-expression expression)
      "Write the report prefix for checked EXPRESSION."
      (newline)
      (check:write expression)
      (display " => "))

    (define (check:report-actual-result actual-result)
      "Write ACTUAL-RESULT in a check report."
      (check:write actual-result)
      (display " ; "))

    (define (check:report-correct cases)
      "Write a correct-check report for CASES checked cases."
      (display "correct")
      (if (not (= cases 1))
          (begin
            (display " (")
            (display cases)
            (display " cases checked)")))
      (newline))

    (define (check:report-failed expected-result)
      "Write a failed-check report with EXPECTED-RESULT."
      (display "*** failed ***")
      (newline)
      (display " ; expected result: ")
      (check:write expected-result)
      (newline))

    (define (check-report)
      "Write an SRFI 78 check summary and the first failed check when enabled.\
"
      #((parameters)
        (returns (type unspecified)
         (description "Unspecified value."))
        (effects state-read port-io))
      (if (>= check:mode 1)
          (begin
            (newline)
            (display "; *** checks *** : ")
            (display check:correct)
            (display " correct, ")
            (display (length check:failed))
            (display " failed.")
            (if (or (null? check:failed) (<= check:mode 1))
                (newline)
                (let* ((w (car (reverse check:failed)))
                       (expression (car w))
                       (actual-result (cadr w))
                       (expected-result (caddr w)))
                  (display " First failed example:")
                  (newline)
                  (check:report-expression expression)
                  (check:report-actual-result actual-result)
                  (check:report-failed expected-result))))))

    (define (check-passed? expected-total-count)
      "Return true if all checks passed and EXPECTED-TOTAL-COUNT succeeded."
      #((parameters
         (expected-total-count (type exact-integer)
          (description "Expected number of correct SRFI 78 checks.")))
        (returns (type boolean)
         (description
           "True when there are no failures and the count matches."))
        (effects state-read))
      (and (= (length check:failed) 0)
           (= check:correct expected-total-count)))

    (define (check:proc expression thunk equal expected-result)
      "Execute one simple SRFI 78 check."
      (case check:mode
        ((0) #f)
        ((1)
         (let ((actual-result (thunk)))
           (if (equal actual-result expected-result)
               (check:add-correct!)
               (check:add-failed! expression actual-result expected-result))))
        ((10)
         (let ((actual-result (thunk)))
           (if (equal actual-result expected-result)
               (check:add-correct!)
               (begin
                 (check:report-expression expression)
                 (check:report-actual-result actual-result)
                 (check:report-failed expected-result)
                 (check:add-failed! expression actual-result
                   expected-result)))))
        ((100)
         (check:report-expression expression)
         (let ((actual-result (thunk)))
           (check:report-actual-result actual-result)
           (if (equal actual-result expected-result)
               (begin
                 (check:report-correct 1)
                 (check:add-correct!))
               (begin
                 (check:report-failed expected-result)
                 (check:add-failed! expression
                                    actual-result
                                    expected-result)))))
        (else (error "unrecognized check:mode" check:mode)))
      (if #f #f))

    ;; Check EXPR against EXPECTED using `equal?' or an explicit predicate.
    (define-syntax check
      (syntax-rules (=>)
        ((check expr => expected)
         (check expr (=> equal?) expected))
        ((check expr (=> equal) expected)
         (if (>= check:mode 1)
             (check:proc 'expr (lambda () expr) equal expected)))))

    (define (check:proc-ec w)
      "Record the result tuple W from one SRFI 78 parametric check."
      (let ((correct? (car w))
            (expression (cadr w))
            (actual-result (caddr w))
            (expected-result (cadddr w))
            (cases (car (cddddr w))))
        (if correct?
            (begin
              (if (>= check:mode 100)
                  (begin
                    (check:report-expression expression)
                    (check:report-actual-result actual-result)
                    (check:report-correct cases)))
              (check:add-correct!))
            (begin
              (if (>= check:mode 10)
                  (begin
                    (check:report-expression expression)
                    (check:report-actual-result actual-result)
                    (check:report-failed expected-result)))
              (check:add-failed! expression
                                 actual-result
                                 expected-result)))))

    ;; Build the SRFI 42 eager-comprehension body for `check-ec'.
    (define-syntax check-ec:make
      (syntax-rules (=>)
        ((check-ec:make qualifiers expr (=> equal) expected (arg ...))
         (if (>= check:mode 1)
             (check:proc-ec
              (let ((cases 0))
                (let ((w (call-with-current-continuation
                          (lambda (return)
                            (do-ec
                             qualifiers
                             (:let equal-pred equal)
                             (:let expected-result expected)
                             (:let actual-result
                                   (let ((arg arg) ...)
                                     expr))
                             (begin
                               (set! cases (+ cases 1))
                               (if (not (equal-pred actual-result
                                                    expected-result))
                                   (return
                                    (list
                                     ;; Construct the introduced source head as
                                     ;; a plain datum.  A quoted introduced
                                     ;; identifier can retain macro-renaming
                                     ;; metadata in a self-host expansion and
                                     ;; is not writable as Scheme data.
                                     (list (string->symbol "let")
                                           (list (list 'arg arg) ...)
                                           'expr)
                                     actual-result
                                     expected-result
                                     cases)))))
                            #f))))
                  (if w
                      (cons #f w)
                      (list #t
                            '(check-ec qualifiers
                                       expr (=>
                                             equal)
                                       expected (arg ...))
                            (if #f #f)
                            (if #f #f)
                            cases)))))))))

    ;; Parametric check form over SRFI 42 eager-comprehension qualifiers.
    (define-syntax check-ec
      (syntax-rules (nested =>)
        ((check-ec expr => expected)
         (check-ec:make (nested) expr (=> equal?) expected ()))
        ((check-ec expr (=> equal) expected)
         (check-ec:make (nested) expr (=> equal) expected ()))
        ((check-ec expr => expected (arg ...))
         (check-ec:make (nested) expr (=> equal?) expected (arg ...)))
        ((check-ec expr (=> equal) expected (arg ...))
         (check-ec:make (nested) expr (=> equal) expected (arg ...)))

        ((check-ec qualifiers expr => expected)
         (check-ec:make qualifiers expr (=> equal?) expected ()))
        ((check-ec qualifiers expr (=> equal) expected)
         (check-ec:make qualifiers expr (=> equal) expected ()))
        ((check-ec qualifiers expr => expected (arg ...))
         (check-ec:make qualifiers expr (=> equal?) expected (arg ...)))
        ((check-ec qualifiers expr (=> equal) expected (arg ...))
         (check-ec:make qualifiers expr (=> equal) expected (arg ...)))

        ((check-ec (nested q1 ...) q etc ...)
         (check-ec (nested q1 ... q) etc ...))
        ((check-ec q1 q2 etc ...)
         (check-ec (nested q1 q2) etc ...))))))
