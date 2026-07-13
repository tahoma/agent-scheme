;;; Portable Agent Diff semantic tests.
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

(define (nested-value source)
  "Evaluate SOURCE and return its value or complete error as external text."
  (let ((result (consent-eval-source-result source)))
    (if (eq? (result-field result 'status #f) 'ok)
        (result-field result 'value #f)
        (consent-result->external result))))

(testing-registry-case
 'diff-render '(agent diff records)
 (test-equal
  "proposed edit renders as unified diff"
  "--- before.scm\n+++ after.scm\n@@ -2,1 +2,1 @@\n-old\n+new\n"
  (nested-value
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
        (after \"new\"))))")))

(testing-registry-case
 'diff-no-change '(agent diff records)
 (test-equal
  "no-change diff is explicit and renders empty"
  "(#t #f \"\")"
  (consent-value->external
   (nested-value
    "(import (scheme base) (agent diff))
     (let ((diff (no-change-diff 'buffer \"scratch\")))
       (list (diff? diff)
             (diff-changed? diff)
             (diff-render-unified diff)))"))))

(testing-registry-case
 'diff-yield '(agent diff events)
 (let ((result
        (consent-result->external
         (consent-eval-source-result
          "(import (scheme base) (agent diff))
           (diff-yield (no-change-diff 'buffer \"scratch\"))
           'ok"))))
   (test-assert "successful result" (string-contains? result "(status ok)"))
   (test-assert "yielded diff event"
                (string-contains? result "(events ((yield (diff"))
   (test-assert "no-change status"
                (string-contains? result "(status no-change)"))))

(testing-runner-main "Agent Diff portable semantics" (command-line))
