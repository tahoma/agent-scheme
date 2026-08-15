;;; Portable Agent Helper graph-copy tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (agent helper)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (field-value record name)
  "Return field NAME from helper RECORD, or #f."
  (let loop ((fields (cdr record)))
    (cond
     ((null? fields) #f)
     ((and (pair? (car fields)) (eq? (caar fields) name))
      (cadr (car fields)))
     (else (loop (cdr fields))))))

(testing-registry-case
 'helper-artifact-copy-preserves-topology '(agent helper identity graph)
(let* ((store (consent-make-helper-store))
       (shared (vector 'shared))
       (cycle (cons 'cycle '()))
       (root (vector shared shared cycle)))
  (set-cdr! cycle cycle)
  (let* ((record
          (helper-store-artifact-save!
           store 'session 'topology root '((source test))))
         (copy (field-value record 'value)))
    (test-assert "artifact root is detached"
                 (not (eq? root copy)))
    (test-assert "artifact shared vector remains shared"
                 (eq? (vector-ref copy 0) (vector-ref copy 1)))
    (test-assert "artifact shared vector is detached"
                 (not (eq? shared (vector-ref copy 0))))
    (test-assert "artifact pair cycle is preserved"
                 (eq? (vector-ref copy 2) (cdr (vector-ref copy 2))))
    (vector-set! shared 0 'changed)
    (test-equal "artifact copy ignores later source mutation"
                'shared
                (vector-ref (vector-ref copy 0) 0)))))

(testing-registry-case
 'helper-library-copy-preserves-cycles '(agent helper identity graph)
(let* ((store (consent-make-helper-store))
       (forms (cons 'form '())))
  (set-cdr! forms forms)
  (let* ((record
          (helper-store-save!
           store 'session '(agent helpers cyclic) forms 'test))
         (copy (helper-record-forms record)))
    (test-assert "helper forms are detached"
                 (not (eq? forms copy)))
    (test-assert "helper forms retain their cycle"
                 (eq? copy (cdr copy))))))

(testing-runner-main "Agent Helper portable graph copies" (command-line))
