;;; Portable Agent VCS datum and parser tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (agent vcs)
        (testing registry)
        (testing runner)
        (stdlib testing)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing))

;; NUL separator used by Git's machine-readable formats.
(define nul (string #\null))

(testing-registry-case
 'vcs-status-clean '(agent vcs parser) ("consent-vcs-test.scm" 18)
 (let* ((status
         (parse-git-status-porcelain-v2-z
          (string-append
           "# branch.oid abc123" nul
           "# branch.head main" nul)))
        (branch (vcs-status-branch status)))
   (test-equal "clean branch head" "main"
               (vcs-field-value branch 'head #f))
   (test-equal "clean branch oid" "abc123"
               (vcs-field-value branch 'oid #f))
   (test-assert "clean status has no entries"
                (null? (vcs-status-entries status)))))

(testing-registry-case
 'vcs-status-parser '(agent vcs parser) ("consent-vcs-test.scm" 33)
 (let* ((status
         (parse-git-status-porcelain-v2-z
          (string-append
           "# branch.oid abc123" nul
           "# branch.head main" nul
           "# branch.upstream origin/main" nul
           "# branch.ab +2 -1" nul
           "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb src/main.scm" nul
           "2 R. N... 100644 100644 100644 ccccccc ddddddd R100 src/new.scm" nul
           "src/old.scm" nul
           "? scratch.scm" nul
           "! build/" nul
           "1 .M S.MU 160000 160000 160000 eeeeeee fffffff vendor/lib" nul)))
        (branch (vcs-status-branch status))
        (entries (vcs-status-entries status))
        (regular (car entries))
        (renamed (cadr entries))
        (untracked (list-ref entries 2))
        (ignored (list-ref entries 3))
        (submodule-entry (list-ref entries 4))
        (submodule (vcs-field-value submodule-entry 'submodule #f)))
   (test-equal "branch head" "main"
               (vcs-field-value branch 'head #f))
   (test-equal "branch upstream" "origin/main"
               (vcs-field-value branch 'upstream #f))
   (test-equal "ahead" 2 (vcs-field-value branch 'ahead 0))
   (test-equal "behind" 1 (vcs-field-value branch 'behind 0))
   (test-equal "modified path" "src/main.scm"
               (vcs-status-entry-path regular))
   (test-equal "modified index status" 'modified
               (vcs-status-entry-index-status regular))
   (test-equal "rename path" "src/new.scm"
               (vcs-status-entry-path renamed))
   (test-equal "rename origin" "src/old.scm"
               (vcs-field-value renamed 'orig-path #f))
   (test-equal "rename score" 100
               (vcs-field-value renamed 'score #f))
   (test-equal "untracked entry" 'untracked
               (vcs-field-value untracked 'kind #f))
   (test-equal "ignored entry" 'ignored
               (vcs-field-value ignored 'kind #f))
   (test-equal "submodule path" "vendor/lib"
               (vcs-field-value submodule-entry 'path #f))
   (test-assert "submodule tracked changes"
                (vcs-field-value submodule 'tracked-changes? #f))
   (test-assert "submodule untracked changes"
                (vcs-field-value submodule 'untracked? #f))))

(testing-registry-case
 'vcs-status-detached-conflict '(agent vcs parser)
 ("consent-vcs-test.scm" 83)
 (let* ((status
         (parse-git-status-porcelain-v2-z
          (string-append
           "# branch.oid deadbeef" nul
           "# branch.head (detached)" nul
           "# branch.ab +0 -3" nul
           "u UU N... 100644 100644 100644 100644 "
           "hbase hours htheirs conflict.scm" nul)))
        (branch (vcs-status-branch status))
        (entry (car (vcs-status-entries status)))
        (conflict (vcs-field-value entry 'conflict #f)))
   (test-assert "detached head"
                (vcs-field-value branch 'detached? #f))
   (test-equal "detached branch has no head" #f
               (vcs-field-value branch 'head #f))
   (test-equal "detached branch oid" "deadbeef"
               (vcs-field-value branch 'oid #f))
   (test-equal "detached branch behind" 3
               (vcs-field-value branch 'behind 0))
   (test-assert "conflict predicate" (vcs-status-entry-conflict? entry))
   (test-equal "conflict kind" 'conflicted
               (vcs-field-value entry 'kind #f))
   (test-equal "conflict path" "conflict.scm"
               (vcs-field-value entry 'path #f))
   (test-equal "conflict type" 'both-modified
               (vcs-field-value conflict 'type #f))))

(testing-registry-case
 'vcs-diff-parser '(agent vcs parser) ("consent-vcs-test.scm" 113)
 (let* ((diff
         (parse-git-raw-diff-z
          (string-append
           ":100644 100644 abcdef1 1234567 M" nul
           "src/main.scm" nul
           ":100644 100644 7654321 1111111 R86" nul
           "src/old.scm" nul
           "src/new.scm" nul)))
        (files (vcs-diff-summary-files diff))
        (file (car files))
        (renamed (cadr files)))
   (test-equal "diff status" 'modified
               (vcs-field-value file 'status #f))
   (test-equal "diff path" "src/main.scm"
               (vcs-field-value file 'path #f))
   (test-equal "diff old mode" "100644"
               (vcs-field-value file 'old-mode #f))
   (test-equal "renamed status" 'renamed
               (vcs-field-value renamed 'status #f))
   (test-equal "renamed path" "src/new.scm"
               (vcs-field-value renamed 'path #f))
   (test-equal "renamed origin" "src/old.scm"
               (vcs-field-value renamed 'orig-path #f))
   (test-equal "renamed score" 86
               (vcs-field-value renamed 'score #f))))

(testing-registry-case
 'vcs-request-result '(agent vcs records) ("consent-vcs-test.scm" 141)
 (let* ((request
         (make-vcs-capability-request
          'req-1 'status 'read-only-observation '((path "."))))
        (result
         (make-vcs-capability-result
          'req-1 'ok (make-vcs-outcome 'no-vcs "No repository found."))))
   (test-assert "status is read-only" (vcs-read-only-operation? 'status))
   (test-assert "diff is read-only"
                (vcs-read-only-operation? 'diff-summary))
   (test-assert "commit mutates" (vcs-mutating-operation? 'commit))
   (test-assert "push mutates" (vcs-mutating-operation? 'push))
   (test-equal "request authority" 'read-only-observation
               (vcs-field-value request 'authority #f))
   (test-equal "request operation" 'status
               (vcs-field-value request 'operation #f))
   (test-equal "result status" 'ok
               (vcs-field-value result 'status #f))
   (test-equal "result outcome" 'no-vcs
               (vcs-outcome-status
                (vcs-field-value result 'value #f)))
   (test-equal "timeout outcome" 'timeout
               (vcs-outcome-status
                (make-vcs-outcome 'timeout "Git timed out.")))))

(testing-registry-case
 'vcs-authority '(agent vcs capability) ("consent-vcs-test.scm" 167)
 (test-equal "read authority" 'read-only-observation
             (vcs-operation-required-authority 'status))
 (test-equal "remote mutation authority" 'remote-mutation
             (vcs-operation-required-authority 'push))
 (let* ((request
         (make-vcs-capability-request
          'req-stage 'stage 'repository-mutation
          '((repository "/repo") (paths ("src/main.scm")))))
        (denied (vcs-authorize-capability-request request '() '()))
        (grant
         (make-vcs-capability-grant
          'grant-local 'repository-mutation '(stage commit) "/repo" #f))
        (allowed
         (vcs-authorize-capability-request request (list grant) '()))
        (result
         (make-vcs-capability-result
          'req-stage 'ok (make-vcs-outcome 'ok "Staged selected paths.")))
        (audit (make-vcs-capability-audit request allowed result)))
   (test-equal "missing local grant denies" 'denied
               (vcs-capability-decision-status denied))
   (test-equal "local grant approves" 'approved
               (vcs-capability-decision-status allowed))
   (test-equal "local grant id" 'grant-local
               (vcs-field-value allowed 'grant #f))
   (test-equal "local audit decision" 'approved
               (vcs-field-value audit 'decision #f))
   (test-equal "local audit outcome" 'ok
               (vcs-field-value audit 'outcome #f)))
 (let* ((request
         (make-vcs-capability-request
          'req-push 'push 'remote-mutation
          '((repository "/repo") (remote "origin") (branch "main"))))
        (local-grant
         (make-vcs-capability-grant
          'grant-local 'repository-mutation '(stage commit) "/repo" #f))
        (denied
         (vcs-authorize-capability-request request (list local-grant) '()))
        (approval
         (make-vcs-approval-decision
          'approve-push 'req-push 'approved "User approved push."))
        (allowed
         (vcs-authorize-capability-request request '() (list approval)))
        (result
         (make-vcs-capability-result
          'req-push 'error
          (make-vcs-outcome
           'remote-authentication-failed "Remote rejected credentials.")))
        (audit (make-vcs-capability-audit request allowed result)))
   (test-equal "local grant cannot authorize remote" 'denied
               (vcs-capability-decision-status denied))
   (test-equal "remote approval authorizes" 'approved
               (vcs-capability-decision-status allowed))
   (test-equal "remote approval id" 'approve-push
               (vcs-field-value allowed 'approval #f))
   (test-assert "request marks remote" (vcs-field-value request 'remote? #f))
   (test-assert "audit marks remote" (vcs-field-value audit 'remote? #f))
   (test-equal "remote audit outcome" 'remote-authentication-failed
               (vcs-field-value audit 'outcome #f))))

(testing-registry-case
 'vcs-repository-property '(agent vcs property) ("consent-vcs-test.scm" 228)
 (test-property
  (lambda (path identity)
    (let ((repository (make-vcs-repository 'git path identity)))
      (and (equal? path (vcs-field-value repository 'root #f))
           (equal? identity
                   (vcs-field-value repository 'identity #f)))))
  (list (make-random-string-generator 16 "abcxyz/-_")
        (exact-integer-generator))
  25))

(testing-runner-main "Agent VCS portable semantics" (command-line))
