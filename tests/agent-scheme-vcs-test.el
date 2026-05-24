;;; agent-scheme-vcs-test.el --- VCS datum and parser tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the host-neutral `(agent vcs)' contract and its pure
;; Git machine-format parsers.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)

(defun agent-scheme-vcs-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source)))

(ert-deftest agent-scheme-vcs-test-status-parser-covers-clean-state ()
  "Parse a clean porcelain v2 branch header with no status entries."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define nul (string #\\null))
      (define status
        (parse-git-status-porcelain-v2-z
         (string-append
          \"# branch.oid abc123\" nul
          \"# branch.head main\" nul)))
      (define branch (vcs-status-branch status))
      (list
       (vcs-field-value branch 'head #f)
       (vcs-field-value branch 'oid #f)
       (null? (vcs-status-entries status)))")
    "(\"main\" \"abc123\" #t)")))

(ert-deftest agent-scheme-vcs-test-status-parser-covers-worktree-states ()
  "Parse representative porcelain v2 status records into VCS datums."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define nul (string #\\null))
      (define status
        (parse-git-status-porcelain-v2-z
         (string-append
          \"# branch.oid abc123\" nul
          \"# branch.head main\" nul
          \"# branch.upstream origin/main\" nul
          \"# branch.ab +2 -1\" nul
          \"1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb src/main.scm\" nul
          \"2 R. N... 100644 100644 100644 ccccccc ddddddd R100 src/new.scm\" nul
          \"src/old.scm\" nul
          \"? scratch.scm\" nul
          \"! build/\" nul
          \"1 .M S.MU 160000 160000 160000 eeeeeee fffffff vendor/lib\" nul)))
      (define branch (vcs-status-branch status))
      (define entries (vcs-status-entries status))
      (define regular (car entries))
      (define renamed (cadr entries))
      (define untracked (list-ref entries 2))
      (define ignored (list-ref entries 3))
      (define submodule-entry (list-ref entries 4))
      (define submodule (vcs-field-value submodule-entry 'submodule #f))
      (list
       (vcs-field-value branch 'head #f)
       (vcs-field-value branch 'upstream #f)
       (vcs-field-value branch 'ahead 0)
       (vcs-field-value branch 'behind 0)
       (vcs-field-value regular 'kind #f)
       (vcs-field-value regular 'path #f)
       (vcs-field-value regular 'index-status #f)
       (vcs-field-value regular 'worktree-status #f)
       (vcs-field-value renamed 'kind #f)
       (vcs-field-value renamed 'path #f)
       (vcs-field-value renamed 'orig-path #f)
       (vcs-field-value renamed 'score #f)
       (vcs-field-value untracked 'kind #f)
       (vcs-field-value ignored 'kind #f)
       (vcs-field-value submodule-entry 'path #f)
       (vcs-field-value submodule 'commit-changed? #f)
       (vcs-field-value submodule 'tracked-changes? #f)
       (vcs-field-value submodule 'untracked? #f))")
    "(\"main\" \"origin/main\" 2 1 modified \"src/main.scm\" modified unchanged renamed \"src/new.scm\" \"src/old.scm\" 100 untracked ignored \"vendor/lib\" #f #t #t)")))

(ert-deftest agent-scheme-vcs-test-status-parser-covers-detached-and-conflict ()
  "Represent detached HEAD and unmerged porcelain v2 records explicitly."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define nul (string #\\null))
      (define status
        (parse-git-status-porcelain-v2-z
         (string-append
          \"# branch.oid deadbeef\" nul
          \"# branch.head (detached)\" nul
          \"# branch.ab +0 -3\" nul
          \"u UU N... 100644 100644 100644 100644 hbase hours htheirs conflict.scm\" nul)))
      (define branch (vcs-status-branch status))
      (define entry (car (vcs-status-entries status)))
      (define conflict (vcs-field-value entry 'conflict #f))
      (list
       (vcs-field-value branch 'detached? #f)
       (vcs-field-value branch 'head 'missing)
       (vcs-field-value branch 'oid #f)
       (vcs-field-value branch 'ahead 9)
       (vcs-field-value branch 'behind 0)
       (vcs-status-entry-conflict? entry)
       (vcs-field-value entry 'kind #f)
       (vcs-field-value entry 'path #f)
       (vcs-field-value conflict 'type #f))")
    "(#t #f \"deadbeef\" 0 3 #t conflicted \"conflict.scm\" both-modified)")))

(ert-deftest agent-scheme-vcs-test-raw-diff-parser-covers-file-summaries ()
  "Parse Git raw diff -z records into portable diff summary datums."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define nul (string #\\null))
      (define diff
        (parse-git-raw-diff-z
         (string-append
          \":100644 100644 abcdef1 1234567 M\" nul
          \"src/main.scm\" nul
          \":100644 100644 7654321 1111111 R86\" nul
          \"src/old.scm\" nul
          \"src/new.scm\" nul)))
      (define files (vcs-diff-summary-files diff))
      (define modified (car files))
      (define renamed (cadr files))
      (list
       (vcs-field-value modified 'status #f)
       (vcs-field-value modified 'path #f)
       (vcs-field-value modified 'old-mode #f)
       (vcs-field-value renamed 'status #f)
       (vcs-field-value renamed 'path #f)
       (vcs-field-value renamed 'orig-path #f)
       (vcs-field-value renamed 'score #f))")
    "(modified \"src/main.scm\" \"100644\" renamed \"src/new.scm\" \"src/old.scm\" 86)")))

(ert-deftest agent-scheme-vcs-test-request-result-and-outcome-datums ()
  "VCS request and result datums distinguish observation from mutation."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define request
        (make-vcs-capability-request
         'req-1
         'status
         'read-only-observation
         '((path \".\"))))
      (define result
        (make-vcs-capability-result
         'req-1
         'ok
         (make-vcs-outcome 'no-vcs \"No repository found.\")))
      (list
       (vcs-read-only-operation? 'status)
       (vcs-read-only-operation? 'diff-summary)
       (vcs-mutating-operation? 'commit)
       (vcs-mutating-operation? 'push)
       (vcs-field-value request 'authority #f)
       (vcs-field-value request 'operation #f)
       (vcs-field-value result 'status #f)
       (vcs-outcome-status (vcs-field-value result 'value #f))
       (vcs-outcome-status (make-vcs-outcome 'timeout \"Git timed out.\")))")
    "(#t #t #t #t read-only-observation status ok no-vcs timeout)")))

;;; agent-scheme-vcs-test.el ends here
