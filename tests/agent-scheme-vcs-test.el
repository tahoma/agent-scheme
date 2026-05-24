;;; agent-scheme-vcs-test.el --- VCS datum and parser tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the host-neutral `(agent vcs)' contract and its pure
;; Git machine-format parsers.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-result)

(defun agent-scheme-vcs-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source)))

(defun agent-scheme-vcs-test--result-external (source)
  "Evaluate SOURCE and return its stable evaluation-result text."
  (agent-scheme-result->external
   (agent-scheme-eval-source-result source)))

(defun agent-scheme-vcs-test--contains-p (text needle)
  "Return non-nil when TEXT contains NEEDLE."
  (string-match-p (regexp-quote needle) text))

(defun agent-scheme-vcs-test--audit-strings ()
  "Return recent audit entries as stable external strings."
  (mapcar #'agent-scheme-result->external
          (agent-scheme-audit-recent-entries)))

(defun agent-scheme-vcs-test--audit-entry-matching (&rest snippets)
  "Return a recent audit entry containing all SNIPPETS."
  (seq-find
   (lambda (entry)
     (seq-every-p
      (lambda (snippet)
        (agent-scheme-vcs-test--contains-p entry snippet))
      snippets))
   (agent-scheme-vcs-test--audit-strings)))

(defun agent-scheme-vcs-test--actions (overrides)
  "Return policy category actions with OVERRIDES applied."
  (append overrides
          (seq-remove
           (lambda (entry) (assq (car entry) overrides))
           agent-scheme-policy-category-actions)))

(defun agent-scheme-vcs-test--write-file (path text)
  "Write TEXT to PATH, creating parent directories."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert text)))

(defun agent-scheme-vcs-test--git (root &rest arguments)
  "Run Git in ROOT with ARGUMENTS and return stdout."
  (let ((default-directory root))
    (with-temp-buffer
      (let ((status (apply #'process-file
                           "git"
                           nil
                           (current-buffer)
                           nil
                           arguments)))
        (unless (equal status 0)
          (error "git %S failed with %S: %s"
                 arguments status (buffer-string))))
      (buffer-string))))

(defun agent-scheme-vcs-test--cached-files (root)
  "Return staged file names in ROOT."
  (split-string
   (agent-scheme-vcs-test--git root "diff" "--cached" "--name-only")
   "\n"
   t))

(defun agent-scheme-vcs-test--current-branch (root)
  "Return the current branch name in ROOT."
  (string-trim
   (agent-scheme-vcs-test--git root "branch" "--show-current")))

(defun agent-scheme-vcs-test--make-git-repo ()
  "Return a temporary Git repository with one modified tracked file."
  (unless (executable-find "git")
    (ert-skip "git executable is not available"))
  (let* ((root (file-name-as-directory
                (make-temp-file "agent-scheme-emacs-vcs-" t)))
         (tracked (expand-file-name "src/main.scm" root))
         (untracked (expand-file-name "scratch.scm" root)))
    (agent-scheme-vcs-test--git root "init" "-q" "-b" "main")
    (agent-scheme-vcs-test--write-file tracked "(define value 1)\n")
    (agent-scheme-vcs-test--git root "add" "src/main.scm")
    (agent-scheme-vcs-test--git
     root
     "-c" "user.name=Agent Scheme Tests"
     "-c" "user.email=agent-scheme-tests@example.invalid"
     "commit" "-q" "-m" "initial commit")
    (agent-scheme-vcs-test--write-file tracked "(define value 2)\n")
    (agent-scheme-vcs-test--write-file untracked "(define scratch #t)\n")
    root))

(defmacro agent-scheme-vcs-test--with-project-root (root &rest body)
  "Run BODY with current Emacs project rooted at ROOT."
  (declare (indent 1))
  `(let ((default-directory ,root))
     (cl-letf (((symbol-function 'project-current)
                (lambda (&optional _maybe-prompt _directory)
                  (cons 'transient ,root))))
       ,@body)))

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

(ert-deftest agent-scheme-vcs-test-local-mutation-requires-policy-grant ()
  "Local mutating VCS operations fail closed without mutation authority."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define request
        (make-vcs-capability-request
         'req-stage
         'stage
         'repository-mutation
         '((repository \"/repo\") (paths (\"src/main.scm\")))))
      (define denied
        (vcs-authorize-capability-request request '() '()))
      (define grant
        (make-vcs-capability-grant
         'grant-local
         'repository-mutation
         '(stage commit)
         \"/repo\"
         #f))
      (define allowed
        (vcs-authorize-capability-request request (list grant) '()))
      (define result
        (make-vcs-capability-result
         'req-stage
         'ok
         (make-vcs-outcome 'ok \"Staged selected paths.\")))
      (define audit
        (make-vcs-capability-audit request allowed result))
      (list
       (vcs-mutating-operation? 'stage)
       (vcs-remote-operation? 'stage)
       (vcs-operation-required-authority 'stage)
       (vcs-capability-request? request)
       (vcs-field-value request 'required-authority #f)
       (vcs-capability-decision-status denied)
       (vcs-field-value denied 'reason #f)
       (vcs-capability-decision-status allowed)
       (vcs-field-value allowed 'grant #f)
       (vcs-field-value audit 'event #f)
       (vcs-field-value audit 'decision #f)
       (vcs-field-value audit 'result #f)
       (vcs-field-value audit 'outcome #f))")
    "(#t #f repository-mutation #t repository-mutation denied \"missing VCS mutation grant or approval\" approved grant-local vcs-capability-audit approved ok ok)")))

(ert-deftest agent-scheme-vcs-test-remote-mutation-uses-separate-authority ()
  "Remote VCS operations require explicit remote mutation authority or approval."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (agent vcs))
      (define request
        (make-vcs-capability-request
         'req-push
         'push
         'remote-mutation
         '((repository \"/repo\") (remote \"origin\") (branch \"main\"))))
      (define local-grant
        (make-vcs-capability-grant
         'grant-local
         'repository-mutation
         '(stage commit)
         \"/repo\"
         #f))
      (define denied
        (vcs-authorize-capability-request request (list local-grant) '()))
      (define approval
        (make-vcs-approval-decision
         'approve-push
         'req-push
         'approved
         \"User approved push.\"))
      (define allowed
        (vcs-authorize-capability-request request '() (list approval)))
      (define result
        (make-vcs-capability-result
         'req-push
         'error
         (make-vcs-outcome
          'remote-authentication-failed
          \"Remote rejected credentials.\")))
      (define audit
        (make-vcs-capability-audit request allowed result))
      (list
       (vcs-remote-operation? 'push)
       (vcs-operation-required-authority 'push)
       (vcs-capability-decision-status denied)
       (vcs-capability-decision-status allowed)
       (vcs-field-value allowed 'approval #f)
       (vcs-field-value request 'remote? #f)
       (vcs-field-value audit 'remote? #f)
       (vcs-field-value audit 'outcome #f)
       (vcs-known-outcome? 'remote-authentication-failed)
       (vcs-known-outcome? 'remote-unavailable))")
    "(#t remote-mutation denied approved approve-push #t #t remote-authentication-failed #t #t)")))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-imports-read-only-bindings ()
  "The `(emacs vcs)' adapter exposes read-only VCS observation procedures."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (emacs vcs))
      (list (procedure? vcs-root)
            (procedure? vcs-branch)
            (procedure? vcs-status)
            (procedure? vcs-diff)
            (procedure? vcs-recent-commits)
            (procedure? vcs-yield))")
    "(#t #t #t #t #t #t)"))
  (let ((names
         (mapcar
          (lambda (spec) (plist-get spec :name))
          (seq-filter
           (lambda (spec)
             (equal (plist-get spec :library) "(emacs vcs)"))
           (agent-scheme-emacs-capability-binding-specs)))))
    (should (equal names
                   '("vcs-root"
                     "vcs-branch"
                     "vcs-status"
                     "vcs-diff"
                     "vcs-recent-commits"
                     "vcs-yield")))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-mutation-imports-separate-bindings ()
  "The mutating VCS adapter surface is separate from read-only observations."
  (should
   (equal
    (agent-scheme-vcs-test--external
     "(import (scheme base) (emacs vcs mutation))
      (list (procedure? vcs-stage!)
            (procedure? vcs-unstage!)
            (procedure? vcs-commit!)
            (procedure? vcs-branch-create!)
            (procedure? vcs-switch!)
            (procedure? vcs-fetch!)
            (procedure? vcs-pull!)
            (procedure? vcs-push!))")
    "(#t #t #t #t #t #t #t #t)"))
  (let ((read-only-names
         (mapcar
          (lambda (spec) (plist-get spec :name))
          (seq-filter
           (lambda (spec)
             (equal (plist-get spec :library) "(emacs vcs)"))
           (agent-scheme-emacs-capability-binding-specs))))
        (mutation-names
         (mapcar
          (lambda (spec) (plist-get spec :name))
          (seq-filter
           (lambda (spec)
             (equal (plist-get spec :library) "(emacs vcs mutation)"))
           (agent-scheme-emacs-capability-binding-specs)))))
    (should (equal read-only-names
                   '("vcs-root"
                     "vcs-branch"
                     "vcs-status"
                     "vcs-diff"
                     "vcs-recent-commits"
                     "vcs-yield")))
    (should (equal mutation-names
                   '("vcs-stage!"
                     "vcs-unstage!"
                     "vcs-commit!"
                     "vcs-branch-create!"
                     "vcs-switch!"
                     "vcs-fetch!"
                     "vcs-pull!"
                     "vcs-push!")))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-stage-denies-without-vcs-authority ()
  "Stage requests fail closed without a VCS grant or approval."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . allow))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (should
           (equal
            (agent-scheme-vcs-test--external
             "(import (scheme base) (agent vcs) (emacs vcs mutation))
              (define result
                (vcs-stage! '((paths (\"src/main.scm\")))))
              (define outcome (vcs-field-value result 'value #f))
              (list
               (vcs-field-value result 'status #f)
               (vcs-outcome-status outcome)
               (vcs-field-value outcome 'message #f))")
            "(denied denied \"missing VCS mutation grant or approval\")"))
          (should (equal (agent-scheme-vcs-test--cached-files root) nil))
          (should
           (agent-scheme-vcs-test--audit-entry-matching
            "(event vcs-capability-audit)"
            "(operation stage)"
            "(decision denied)"
            "(outcome denied)")))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-stage-denies-by-host-policy ()
  "Host policy denial stops a VCS mutation before Git changes the index."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . deny))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (should-error
           (agent-scheme-vcs-test--external
            "(import (scheme base)
                     (agent vcs)
                     (emacs vcs)
                     (emacs vcs mutation))
             (define repository
               (vcs-field-value (vcs-root) 'root #f))
             (define grant
               (make-vcs-capability-grant
                'grant-local
                'repository-mutation
                '(stage)
                repository
                #f))
             (vcs-stage!
              `((paths (\"src/main.scm\"))
                (grants (,grant))))")
           :type 'agent-scheme-policy-error)
          (should (equal (agent-scheme-vcs-test--cached-files root) nil))
          (should
           (agent-scheme-vcs-test--audit-entry-matching
            "(event capability-call)"
            "(category vcs-mutation)"
            "(operation \"vcs-stage!\")"
            "(decision denied)")))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-stage-with-grant-mutates-index ()
  "A scoped VCS grant allows staging selected paths and audits the result."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . allow))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (should
           (equal
            (agent-scheme-vcs-test--external
             "(import (scheme base)
                      (agent vcs)
                      (emacs vcs)
                      (emacs vcs mutation))
              (define repository
                (vcs-field-value (vcs-root) 'root #f))
              (define grant
                (make-vcs-capability-grant
                 'grant-local
                 'repository-mutation
                 '(stage)
                 repository
                 #f))
              (define result
                (vcs-stage!
                 `((paths (\"src/main.scm\"))
                   (grants (,grant)))))
              (define outcome (vcs-field-value result 'value #f))
              (list
               (vcs-field-value result 'status #f)
               (vcs-outcome-status outcome))")
            "(ok ok)"))
          (should (equal (agent-scheme-vcs-test--cached-files root)
                         '("src/main.scm")))
          (should
           (agent-scheme-vcs-test--audit-entry-matching
            "(event vcs-capability-audit)"
            "(operation stage)"
            "(decision approved)"
            "(result ok)"
            "(outcome ok)")))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-commit-branch-and-switch-with-grant ()
  "Representative local mutations commit, create a branch, and switch to it."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . allow))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (progn
          (agent-scheme-vcs-test--git
           root "config" "user.name" "Agent Scheme Tests")
          (agent-scheme-vcs-test--git
           root "config" "user.email" "agent-scheme-tests@example.invalid")
          (agent-scheme-vcs-test--with-project-root root
            (agent-scheme-audit-clear)
            (should
             (equal
              (agent-scheme-vcs-test--external
               "(import (scheme base)
                        (agent vcs)
                        (emacs vcs)
                        (emacs vcs mutation))
                (define repository
                  (vcs-field-value (vcs-root) 'root #f))
                (define grant
                  (make-vcs-capability-grant
                   'grant-local
                   'repository-mutation
                   '(stage commit branch-create switch)
                   repository
                   #f))
                (define staged
                  (vcs-stage!
                   `((paths (\"src/main.scm\"))
                     (grants (,grant)))))
                (define committed
                  (vcs-commit!
                   `((message \"follow-up commit\")
                     (grants (,grant)))))
                (define branched
                  (vcs-branch-create!
                   `((name \"feature/topic\")
                     (grants (,grant)))))
                (define switched
                  (vcs-switch!
                   `((branch \"feature/topic\")
                     (grants (,grant)))))
                (list
                 (vcs-outcome-status
                  (vcs-field-value staged 'value #f))
                 (vcs-outcome-status
                  (vcs-field-value committed 'value #f))
                 (vcs-field-value
                  (car (vcs-recent-commits 1))
                  'subject
                  #f)
                 (vcs-outcome-status
                  (vcs-field-value branched 'value #f))
                 (vcs-outcome-status
                  (vcs-field-value switched 'value #f)))")
              "(ok ok \"follow-up commit\" ok ok)"))
            (should (equal (agent-scheme-vcs-test--current-branch root)
                           "feature/topic"))
            (dolist (operation '("commit" "branch-create" "switch"))
              (should
               (agent-scheme-vcs-test--audit-entry-matching
                "(event vcs-capability-audit)"
                (format "(operation %s)" operation)
                "(decision approved)"
                "(result ok)"
                "(outcome ok)")))))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-push-intent-is-authorized-without-live-remote ()
  "Push intent uses VCS authority records and does not require a live remote."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . allow))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (should
           (equal
            (agent-scheme-vcs-test--external
             "(import (scheme base)
                      (agent vcs)
                      (emacs vcs)
                      (emacs vcs mutation))
              (define repository
                (vcs-field-value (vcs-root) 'root #f))
              (define denied
                (vcs-push! '((remote \"origin\"))))
              (define grant
                (make-vcs-capability-grant
                 'grant-push
                 'remote-mutation
                 '(push)
                 repository
                 \"origin\"))
              (define authorized
                (vcs-push!
                 `((remote \"origin\")
                   (grants (,grant)))))
              (list
               (vcs-field-value denied 'status #f)
               (vcs-outcome-status
                (vcs-field-value denied 'value #f))
               (vcs-field-value authorized 'status #f)
               (vcs-outcome-status
                (vcs-field-value authorized 'value #f)))")
            "(denied denied error remote-unavailable)"))
          (should
           (agent-scheme-vcs-test--audit-entry-matching
            "(event vcs-capability-audit)"
            "(operation push)"
            "(authority remote-mutation)"
            "(remote? #t)"
            "(decision approved)"
            "(outcome remote-unavailable)")))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-fetch-and-pull-intents-authorized-without-live-remote ()
  "Fetch and pull intents use remote authority without requiring live remotes."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . allow))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (should
           (equal
            (agent-scheme-vcs-test--external
             "(import (scheme base)
                      (agent vcs)
                      (emacs vcs)
                      (emacs vcs mutation))
              (define repository
                (vcs-field-value (vcs-root) 'root #f))
              (define grant
                (make-vcs-capability-grant
                 'grant-remote
                 'remote-mutation
                 '(fetch pull)
                 repository
                 \"origin\"))
              (define fetched
                (vcs-fetch!
                 `((remote \"origin\")
                   (grants (,grant)))))
              (define pulled
                (vcs-pull!
                 `((remote \"origin\")
                   (grants (,grant)))))
              (list
               (vcs-field-value fetched 'status #f)
               (vcs-outcome-status
                (vcs-field-value fetched 'value #f))
               (vcs-field-value pulled 'status #f)
               (vcs-outcome-status
                (vcs-field-value pulled 'value #f)))")
            "(error remote-unavailable error remote-unavailable)"))
          (dolist (operation '("fetch" "pull"))
            (should
             (agent-scheme-vcs-test--audit-entry-matching
              "(event vcs-capability-audit)"
              (format "(operation %s)" operation)
              "(authority remote-mutation)"
              "(remote? #t)"
              "(decision approved)"
              "(outcome remote-unavailable)"))))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-push-redacts-credentialed-remote-input ()
  "Credentialed remote-looking input is denied without leaking audit text."
  (let ((agent-scheme-policy-category-actions
         (agent-scheme-vcs-test--actions '((vcs-mutation . allow))))
        (root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (should
           (equal
            (agent-scheme-vcs-test--external
             "(import (scheme base)
                      (agent vcs)
                      (emacs vcs)
                      (emacs vcs mutation))
              (define repository
                (vcs-field-value (vcs-root) 'root #f))
              (define grant
                (make-vcs-capability-grant
                 'grant-push-any
                 'remote-mutation
                 '(push)
                 repository
                 'all))
              (define result
                (vcs-push!
                 `((remote \"https://token@example.com/repo.git\")
                   (grants (,grant)))))
              (define outcome (vcs-field-value result 'value #f))
              (list
               (vcs-field-value result 'status #f)
               (vcs-outcome-status outcome)
               (vcs-field-value outcome 'message #f))")
            "(error permission-denied \"VCS remote must be a remote name, not a URL.\")"))
          (let ((audit
                 (agent-scheme-vcs-test--audit-entry-matching
                  "(event vcs-capability-audit)"
                  "(operation push)"
                  "(outcome permission-denied)")))
            (should audit)
            (should-not
             (agent-scheme-vcs-test--contains-p
              audit
              "token@example.com"))
            (should
             (agent-scheme-vcs-test--contains-p
              audit
              "[redacted]"))))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-maps-git-status-diff-and-log ()
  "The Emacs adapter maps Git observations into shared VCS datums."
  (let ((root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (let ((external
                 (agent-scheme-vcs-test--external
                  "(import (scheme base) (agent vcs) (emacs vcs))
                   (define repository (vcs-root))
                   (define branch (vcs-branch))
                   (define status (vcs-status '()))
                   (define entries (vcs-status-entries status))
                   (define diff (vcs-diff '()))
                   (define diff-file (car (vcs-diff-summary-files diff)))
                   (define commit (car (vcs-recent-commits 1)))
                   (list
                    (vcs-field-value repository 'system #f)
                    (vcs-field-value repository 'root #f)
                    (vcs-field-value branch 'head #f)
                    (vcs-field-value branch 'detached? #f)
                    (map vcs-status-entry-kind entries)
                    (map vcs-status-entry-path entries)
                    (vcs-field-value diff-file 'status #f)
                    (vcs-field-value diff-file 'path #f)
                    (vcs-field-value commit 'subject #f))")))
            (should
             (agent-scheme-vcs-test--contains-p
              external
              (format "(git %S \"main\" #f (modified untracked)"
                      (directory-file-name (file-truename root)))))
            (should
             (agent-scheme-vcs-test--contains-p
              external
              "(\"src/main.scm\" \"scratch.scm\") modified \"src/main.scm\" \"initial commit\")"))))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-no-vc-is-explicit ()
  "The Emacs VCS adapter returns explicit no-vcs outcomes outside repositories."
  (let ((root (file-name-as-directory
               (make-temp-file "agent-scheme-no-vcs-" t))))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (should
           (equal
            (agent-scheme-vcs-test--external
             "(import (scheme base) (agent vcs) (emacs vcs))
              (define status (vcs-status '()))
              (list
               (vcs-outcome-status (vcs-root))
               (vcs-outcome-status (vcs-branch))
               (vcs-field-value status 'system #f)
               (vcs-outcome-status
                (vcs-field-value status 'outcome #f))
               (vcs-status-entries status)
               (vcs-diff-summary-files (vcs-diff '()))
               (vcs-recent-commits 3))")
            "(no-vcs no-vcs none no-vcs () () ())")))
      (delete-directory root t))))

(ert-deftest agent-scheme-vcs-test-emacs-vcs-yields-and-audits ()
  "VCS adapter observations are yieldable and audited as read-only capability calls."
  (let ((root (agent-scheme-vcs-test--make-git-repo)))
    (unwind-protect
        (agent-scheme-vcs-test--with-project-root root
          (agent-scheme-audit-clear)
          (let ((result
                 (agent-scheme-vcs-test--result-external
                  "(import (scheme base) (emacs vcs))
                   (vcs-yield (vcs-status '()))
                   'ok")))
            (should (agent-scheme-vcs-test--contains-p result "(status ok)"))
            (should
             (agent-scheme-vcs-test--contains-p
              result
              "(events ((yield (vcs-status")))
            (should
             (agent-scheme-vcs-test--audit-entry-matching
              "(event capability-result)"
              "(category emacs-read-only)"
              "(operation \"vcs-status\")"
              "(library \"(emacs vcs)\")"
              "(outcome success)"
              "(decision completed)")))
      (delete-directory root t))))

;;; agent-scheme-vcs-test.el ends here
