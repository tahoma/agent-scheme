;;; Portable Agent Plan semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (agent plan)
        (development testing harness)
        (stdlib testing)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing))

;; Mutable store shared by the sequential plan lifecycle checks.
(define store (consent-make-plan-store))

(define (raises? thunk)
  "Return true when THUNK raises."
  (guard (condition (else #t)) (thunk) #f))

(consent-test-run "Agent Plan portable semantics"
  (test-equal "scopes" '(fresh session project) consent-plan-scopes)
  (test-equal "statuses"
              '(pending active blocked done cancelled failed)
              consent-plan-statuses)
  (test-assert "store predicate" (consent-plan-store? store))
  (let ((created
         (plan-store-create!
          store
          '(plan
            (id launch)
            (scope project)
            (goal "Expose planning data")
            (memory important)
            (steps (((id reader) (status pending))))))))
    (test-equal "record id" 'launch (plan-record-id created))
    (test-equal "record scope" 'project (plan-record-scope created))
    (test-assert "memory importance"
                 (plan-memory-important? '((memory important))))
    (test-equal "project list" (list created)
                (plan-store-list store 'project)))
  (let ((updated
         (plan-store-step-add!
          store 'launch
          '((id tests) (status pending) (goal "Run plan tests")))))
    (test-equal "added step" 'tests
                (plan-step-id (cadr (plan-record-steps updated)))))
  (let ((updated (plan-store-step-status! store 'launch 'reader 'done)))
    (test-equal "step status" 'done
                (plan-step-status (car (plan-record-steps updated)))))
  (let ((updated (plan-store-status! store 'launch 'active)))
    (test-equal "updated record is addressable" updated
                (plan-store-ref store 'launch)))
  (test-assert "unknown plan fails"
               (raises? (lambda ()
                          (plan-store-step-add! store 'missing '((id x))))))
  (test-assert "unknown step status fails"
               (raises? (lambda ()
                          (plan-store-step-status!
                           store 'launch 'reader 'unknown))))
  (test-assert "unknown plan status fails"
               (raises? (lambda ()
                          (plan-store-status! store 'launch 'unknown))))
  (test-property
   (lambda (index)
     (let* ((status (list-ref consent-plan-statuses index))
            (updated (plan-store-status! store 'launch status)))
       (eq? status
            (let ((entry (assq 'status (cdr updated))))
              (and entry (cadr entry))))))
   (list (make-random-integer-generator
          0 (length consent-plan-statuses)))
   25))
