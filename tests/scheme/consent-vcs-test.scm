;;; Portable Agent VCS datum and parser tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (agent vcs)
        (development testing harness)
        (stdlib testing)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing))

;; NUL separator used by Git's `-z' machine-readable output formats.
(define nul (string #\null))

(consent-test-run "Agent VCS portable semantics"
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
            "? scratch.scm" nul)))
         (branch (vcs-status-branch status))
         (entries (vcs-status-entries status))
         (regular (car entries))
         (renamed (cadr entries)))
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
                (vcs-field-value renamed 'orig-path #f)))
  (let* ((diff
          (parse-git-raw-diff-z
           (string-append
            ":100644 100644 abcdef1 1234567 M" nul
            "src/main.scm" nul)))
         (file (car (vcs-diff-summary-files diff))))
    (test-equal "diff status" 'modified
                (vcs-field-value file 'status #f))
    (test-equal "diff path" "src/main.scm"
                (vcs-field-value file 'path #f)))
  (test-equal "read authority" 'read-only-observation
              (vcs-operation-required-authority 'status))
  (test-equal "remote mutation authority" 'remote-mutation
              (vcs-operation-required-authority 'push))
  (test-property
   (lambda (path identity)
     (let ((repository (make-vcs-repository 'git path identity)))
       (and (equal? path (vcs-field-value repository 'root #f))
            (equal? identity
                    (vcs-field-value repository 'identity #f)))))
   (list (make-random-string-generator 16 "abcxyz/-_")
         (exact-integer-generator))
   25))
