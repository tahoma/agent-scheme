;;; Portable Agent Session lifecycle tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (agent session)
        (testing registry)
        (testing runner)
        (stdlib testing))

(define (field-value datum name default)
  "Return field NAME from DATUM, or DEFAULT."
  (let ((entry (and (pair? datum) (assq name (cdr datum)))))
    (if entry (cadr entry) default)))

(testing-registry-case
 'session-store-lifecycle '(agent session lifecycle)
 (let* ((store (consent-make-session-store))
        (created
         (session-store-create!
          store 'named
          '((id work-main)
            (project-root "/project")
            (created-at 1))))
        (suspended
         (session-store-suspend!
          store 'work-main
          '((definitions (answer))
            (memory ((fact 42)))
            (handles (h-stale)))))
        (resumed (session-store-resume! store 'work-main))
        (snapshot
         (session-store-snapshot!
          store 'work-main
          '((id snap-main)
            (stale-handles (h-stale))
            (created-at 2))))
        (fork
         (session-store-fork!
          store 'work-main
          '((id work-copy) (created-at 3))))
        (retired (session-store-retire! store 'work-main)))
   (test-equal "created id" 'work-main (session-datum-id created))
   (test-equal "suspended status" 'suspended
               (field-value suspended 'status #f))
   (test-equal "resumed status" 'active
               (field-value resumed 'status #f))
   (test-equal "snapshot tag" 'session-snapshot (car snapshot))
   (test-equal "snapshot id" 'snap-main
               (field-value snapshot 'id #f))
   (test-equal "snapshot source" 'work-main
               (field-value snapshot 'source-session #f))
   (test-equal "snapshot definitions" '(answer)
               (field-value snapshot 'definitions '()))
   (test-equal "snapshot stale handles" '(h-stale)
               (field-value snapshot 'stale-handles '()))
   (test-assert "snapshot excludes blind host restoration"
                (memq 'stale-emacs-handles
                      (field-value snapshot 'never-restore '())))
   (test-equal "fork id" 'work-copy (session-datum-id fork))
   (test-equal "fork status" 'new (field-value fork 'status #f))
   (test-equal "fork source" 'work-main
               (field-value fork 'forked-from #f))
   (test-equal "retired status" 'retired
               (field-value retired 'status #f))
   (test-equal "retirement clears handles" '() (session-handles retired))))

(testing-registry-case
 'session-store-validation '(agent session error)
 (let ((store (consent-make-session-store)))
   (session-store-create! store 'named '((id retired-session)))
   (session-store-retire! store 'retired-session)
   (test-error "retired session cannot resume"
               (session-store-resume! store 'retired-session))
   (test-error "unknown session cannot suspend"
               (session-store-suspend! store 'missing))))

(testing-runner-main "Agent Session store portable semantics" (command-line))
