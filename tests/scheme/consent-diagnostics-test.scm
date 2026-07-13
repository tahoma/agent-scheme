;;; Portable Agent Diagnostics semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (only (consent eval)
              consent-eval-source
              consent-eval-source-result
              consent-value->external)
        (only (consent result)
              consent-result->external)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (string-contains? text needle)
  "Return true when TEXT contains NEEDLE."
  (let ((text-length (string-length text))
        (needle-length (string-length needle)))
    (let loop ((index 0))
      (and (<= (+ index needle-length) text-length)
           (or (string=? needle
                         (substring text index (+ index needle-length)))
               (loop (+ index 1)))))))

(define (result-field result name default)
  "Return field NAME from evaluation RESULT, or DEFAULT."
  (let ((entry (and (pair? result) (assq name (cdr result)))))
    (if entry (cadr entry) default)))

(define (nested-value-external source)
  "Evaluate SOURCE and return its value or complete error as external text."
  (let ((result (consent-eval-source-result source)))
    (if (eq? (result-field result 'status #f) 'ok)
        (consent-value->external (result-field result 'value #f))
        (consent-result->external result))))

(testing-registry-case
 'diagnostics-records '(agent diagnostics records)
 ("consent-diagnostics-test.scm" 39)
 (test-equal
  "diagnostic records"
  (string-append
   "(#t #t error \"Unbound identifier\" "
   "(diagnostic-range (start 3) (end 9) (line 1) (column 3) "
   "(end-line 1) (end-column 9)) ok 1)")
  (nested-value-external
    "(import (scheme base) (agent diagnostics))
     (define range (make-diagnostic-range 3 9 1 3 1 9))
     (define diagnostic
       (make-diagnostic 'error \"Unbound identifier\" 'flymake
                        \"src/main.scm\" \"main.scm\" range
                        '((code \"E1\"))))
     (define snapshot
       (make-diagnostics-snapshot 'ok 'buffer \"main.scm\"
                                  \"src/main.scm\"
                                  (list diagnostic) '()))
     (list (diagnostic? diagnostic)
           (diagnostics-snapshot? snapshot)
           (diagnostic-severity diagnostic)
           (diagnostic-message diagnostic)
           (diagnostic-range diagnostic)
           (diagnostics-snapshot-status snapshot)
           (length (diagnostics-snapshot-diagnostics snapshot)))")))

(testing-registry-case
 'diagnostics-capability-records '(agent diagnostics capability)
 ("consent-diagnostics-test.scm" 67)
 (test-equal
  "adapter-neutral request and result datums"
  "(#t #f #t buffer-diagnostics read-only-observation ok ok unavailable)"
  (nested-value-external
    "(import (scheme base) (agent diagnostics))
     (define request
       (make-diagnostics-capability-request
        'req-1 'buffer-diagnostics 'read-only-observation
        '((buffer h-1))))
     (define result
       (make-diagnostics-capability-result
        'req-1 'ok
        (make-diagnostics-snapshot
         'ok 'buffer \"main.scm\" \"src/main.scm\" '() '())))
     (define unavailable
       (make-diagnostics-outcome
        'unavailable \"No diagnostic backend is active.\"))
     (list
      (diagnostics-read-only-operation? 'buffer-diagnostics)
      (diagnostics-read-only-operation? 'apply-code-action)
      (diagnostics-capability-request? request)
      (diagnostics-field-value request 'operation #f)
      (diagnostics-field-value request 'required-authority #f)
      (diagnostics-field-value result 'status #f)
      (diagnostics-snapshot-status
       (diagnostics-field-value result 'value #f))
      (diagnostics-outcome-status unavailable))")))

(testing-registry-case
 'diagnostics-yield '(agent diagnostics events)
 ("consent-diagnostics-test.scm" 98)
 (let ((result
        (consent-result->external
         (consent-eval-source-result
          "(import (scheme base) (agent diagnostics))
           (diagnostics-yield
            (make-diagnostics-snapshot
             'ok 'buffer \"main.scm\" \"src/main.scm\"
             (list
              (make-diagnostic
               'warning \"Unused binding\" 'mock-lsp
               \"src/main.scm\" \"main.scm\"
               (make-diagnostic-range 12 17 2 1 2 6) '()))
             '()))
           'ok"))))
   (test-assert "successful result" (string-contains? result "(status ok)"))
   (test-assert "yielded snapshot"
                (string-contains?
                 result "(events ((yield (diagnostics-snapshot"))
   (test-assert "diagnostic detail"
                (string-contains? result "(message \"Unused binding\")"))))

(testing-runner-main "Agent Diagnostics portable semantics" (command-line))
