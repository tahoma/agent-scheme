;;; agent-scheme-vcs.el --- Emacs VCS adapter datums  -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only Emacs host adapter support for `(emacs vcs)'.  This module maps
;; local Git observations into the host-neutral `(agent vcs)' record vocabulary
;; while keeping process buffers, VC objects, and other host state out of
;; Scheme-visible values.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'vc)
(require 'agent-scheme-result)
(require 'agent-scheme-runtime)

(defcustom agent-scheme-vcs-git-command "git"
  "Git executable used by the read-only Emacs VCS adapter."
  :type 'string
  :group 'agent-scheme)

(defun agent-scheme-vcs--symbol (name)
  "Return NAME as an Agent Scheme symbol datum."
  (agent-scheme--syntax-symbol
   (cond
    ((agent-scheme-symbol-p name)
     (agent-scheme-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun agent-scheme-vcs--field (name &rest values)
  "Return a Scheme-readable VCS field named NAME with VALUES."
  (cons (agent-scheme-vcs--symbol name) values))

(defun agent-scheme-vcs--integer (value)
  "Return VALUE as an exact Agent Scheme integer datum."
  (agent-scheme--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun agent-scheme-vcs--boolean (value)
  "Return VALUE as an Agent Scheme boolean datum."
  (if value agent-scheme-true agent-scheme-false))

(defun agent-scheme-vcs--maybe-string (value)
  "Return VALUE as a plain string datum, or #f when VALUE is nil."
  (if value (substring-no-properties value) agent-scheme-false))

(defun agent-scheme-vcs--record-p (datum tag)
  "Return non-nil when DATUM is a Scheme-readable record tagged TAG."
  (and (consp datum)
       (equal (agent-scheme--symbol-name (car datum)) tag)))

(defun agent-scheme-vcs-field-value (record name &optional default)
  "Return field NAME from RECORD, or DEFAULT when absent."
  (let ((entry
         (seq-find
          (lambda (field)
            (and (consp field)
                 (equal (agent-scheme--symbol-name (car field)) name)))
          (cdr-safe record))))
    (if entry
        (cadr entry)
      default)))

(defun agent-scheme-vcs-outcome (status message)
  "Return a VCS outcome datum with STATUS and MESSAGE."
  (list (agent-scheme-vcs--symbol "vcs-outcome")
        (agent-scheme-vcs--field "status" (agent-scheme-vcs--symbol status))
        (agent-scheme-vcs--field "message" message)))

(defun agent-scheme-vcs-repository (system root identity)
  "Return a repository identity/root datum."
  (list (agent-scheme-vcs--symbol "vcs-repository")
        (agent-scheme-vcs--field "system" (agent-scheme-vcs--symbol system))
        (agent-scheme-vcs--field "root" (agent-scheme-vcs--maybe-string root))
        (agent-scheme-vcs--field "identity"
                                 (agent-scheme-vcs--maybe-string identity))))

(defun agent-scheme-vcs-branch
    (head oid upstream ahead behind detached)
  "Return a branch or detached-head datum."
  (list (agent-scheme-vcs--symbol "vcs-branch")
        (agent-scheme-vcs--field "head" (agent-scheme-vcs--maybe-string head))
        (agent-scheme-vcs--field "oid" (agent-scheme-vcs--maybe-string oid))
        (agent-scheme-vcs--field "upstream"
                                 (agent-scheme-vcs--maybe-string upstream))
        (agent-scheme-vcs--field "ahead" (agent-scheme-vcs--integer ahead))
        (agent-scheme-vcs--field "behind" (agent-scheme-vcs--integer behind))
        (agent-scheme-vcs--field "detached?"
                                 (agent-scheme-vcs--boolean detached))))

(defun agent-scheme-vcs-operation-state (merge rebase cherry-pick bisect)
  "Return merge/rebase/cherry-pick/bisect state as Scheme data."
  (list (agent-scheme-vcs--symbol "vcs-operation-state")
        (agent-scheme-vcs--field "merge" (agent-scheme-vcs--boolean merge))
        (agent-scheme-vcs--field "rebase" (agent-scheme-vcs--boolean rebase))
        (agent-scheme-vcs--field "cherry-pick"
                                 (agent-scheme-vcs--boolean cherry-pick))
        (agent-scheme-vcs--field "bisect" (agent-scheme-vcs--boolean bisect))))

(defun agent-scheme-vcs-conflict-state (type paths)
  "Return a conflict state datum for TYPE and PATHS."
  (list (agent-scheme-vcs--symbol "vcs-conflict-state")
        (agent-scheme-vcs--field "type" (agent-scheme-vcs--symbol type))
        (agent-scheme-vcs--field "paths" paths)))

(defun agent-scheme-vcs-status
    (system repository branch entries operation-state outcome)
  "Return a repository status snapshot datum."
  (list (agent-scheme-vcs--symbol "vcs-status")
        (agent-scheme-vcs--field "system" (agent-scheme-vcs--symbol system))
        (agent-scheme-vcs--field "repository" repository)
        (agent-scheme-vcs--field "branch" branch)
        (agent-scheme-vcs--field "entries" entries)
        (agent-scheme-vcs--field "operation-state" operation-state)
        (agent-scheme-vcs--field "outcome" outcome)))

(defun agent-scheme-vcs-status-entry
    (kind path index-status worktree-status details)
  "Return a worktree/index status entry datum with DETAILS fields."
  (append
   (list (agent-scheme-vcs--symbol "vcs-status-entry")
         (agent-scheme-vcs--field "kind" (agent-scheme-vcs--symbol kind))
         (agent-scheme-vcs--field "path" path)
         (agent-scheme-vcs--field "index-status"
                                  (agent-scheme-vcs--symbol index-status))
         (agent-scheme-vcs--field "worktree-status"
                                  (agent-scheme-vcs--symbol worktree-status)))
   details))

(defun agent-scheme-vcs-diff-summary (system files)
  "Return a file-level VCS diff summary datum."
  (list (agent-scheme-vcs--symbol "vcs-diff-summary")
        (agent-scheme-vcs--field "system" (agent-scheme-vcs--symbol system))
        (agent-scheme-vcs--field "files" files)))

(defun agent-scheme-vcs-diff-file
    (status path orig-path old-mode new-mode old-object new-object score)
  "Return one file-level raw diff summary datum."
  (list (agent-scheme-vcs--symbol "vcs-diff-file")
        (agent-scheme-vcs--field "status" (agent-scheme-vcs--symbol status))
        (agent-scheme-vcs--field "path" path)
        (agent-scheme-vcs--field "orig-path"
                                 (agent-scheme-vcs--maybe-string orig-path))
        (agent-scheme-vcs--field "old-mode" old-mode)
        (agent-scheme-vcs--field "new-mode" new-mode)
        (agent-scheme-vcs--field "old-object" old-object)
        (agent-scheme-vcs--field "new-object" new-object)
        (agent-scheme-vcs--field "score"
                                 (if score
                                     (agent-scheme-vcs--integer score)
                                   agent-scheme-false))))

(defun agent-scheme-vcs-commit-summary
    (oid parents subject author timestamp)
  "Return a compact commit summary datum."
  (list (agent-scheme-vcs--symbol "vcs-commit-summary")
        (agent-scheme-vcs--field "oid" oid)
        (agent-scheme-vcs--field "parents" parents)
        (agent-scheme-vcs--field "subject" subject)
        (agent-scheme-vcs--field "author" author)
        (agent-scheme-vcs--field "timestamp" timestamp)))

(defun agent-scheme-vcs--options-list (options description)
  "Return OPTIONS as a proper list for DESCRIPTION."
  (if (null options)
      nil
    (agent-scheme--proper-list-elements options description)))

(defun agent-scheme-vcs--option-value (options name)
  "Return option NAME from OPTIONS, or nil when absent."
  (when-let ((entry
              (seq-find
               (lambda (field)
                 (and (consp field)
                      (equal (agent-scheme--symbol-name (car field)) name)))
               (agent-scheme-vcs--options-list options "VCS options"))))
    (cadr entry)))

(defun agent-scheme-vcs--scheme-true-p (value)
  "Return non-nil when VALUE is Scheme truth."
  (not (or (null value) (eq value agent-scheme-false))))

(defun agent-scheme-vcs--option-string (options name)
  "Return string option NAME from OPTIONS, or nil when absent."
  (when-let ((value (agent-scheme-vcs--option-value options name)))
    (unless (stringp value)
      (agent-scheme--eval-error
       "VCS option %s expected a string, got %s"
       name
       (agent-scheme-value->external value)))
    (substring-no-properties value)))

(defun agent-scheme-vcs--working-directory (&optional options)
  "Return the directory used for a VCS observation."
  (file-name-as-directory
   (expand-file-name
    (or (agent-scheme-vcs--option-string options "root")
        (agent-scheme-vcs--option-string options "path")
        (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun agent-scheme-vcs--git-executable ()
  "Return the configured Git executable, or nil when unavailable."
  (executable-find agent-scheme-vcs-git-command))

(defun agent-scheme-vcs--run-git (directory &rest arguments)
  "Run Git in DIRECTORY with ARGUMENTS.
Return a plist with `:exit' and `:output', or `:status' when Git is missing."
  (if-let ((git (agent-scheme-vcs--git-executable)))
      (let ((default-directory directory))
        (with-temp-buffer
          (let ((exit (apply #'process-file
                             git nil (current-buffer) nil arguments)))
            (list :exit exit :output (buffer-string)))))
    (list :status 'git-not-found
          :output ""
          :message "Git executable was not found.")))

(defun agent-scheme-vcs--vc-backend (directory)
  "Return the VC backend responsible for DIRECTORY, or nil."
  (ignore-errors
    (vc-responsible-backend directory)))

(defun agent-scheme-vcs--unsupported-backend-outcome (backend)
  "Return an unsupported-VCS outcome for BACKEND."
  (agent-scheme-vcs-outcome
   'unsupported-vcs
   (format "Unsupported VCS backend: %s" backend)))

(defun agent-scheme-vcs--root-info (&optional options)
  "Return root resolution info for OPTIONS."
  (let* ((directory (agent-scheme-vcs--working-directory options))
         (backend (agent-scheme-vcs--vc-backend directory)))
    (cond
     ((and backend (not (eq backend 'Git)))
      (list :status 'unsupported-vcs
            :directory directory
            :backend backend
            :outcome (agent-scheme-vcs--unsupported-backend-outcome backend)))
     (t
      (let ((result
             (agent-scheme-vcs--run-git
              directory "rev-parse" "--show-toplevel")))
        (cond
         ((plist-get result :status)
          (list :status (plist-get result :status)
                :directory directory
                :outcome (agent-scheme-vcs-outcome
                          'git-not-found
                          (plist-get result :message))))
         ((equal (plist-get result :exit) 0)
          (let ((root (string-trim (plist-get result :output))))
            (list :status 'ok
                  :directory directory
                  :root (file-name-as-directory (expand-file-name root)))))
         (t
          (list :status 'no-vcs
                :directory directory
                :outcome (agent-scheme-vcs-outcome
                          'no-vcs
                          "No repository found.")))))))))

(defun agent-scheme-vcs--split-nul (text)
  "Split NUL-delimited Git machine-format TEXT."
  (split-string text "\0" t))

(defun agent-scheme-vcs--split-spaces (text)
  "Split TEXT into non-empty space-separated fields."
  (split-string text " " t))

(defun agent-scheme-vcs--leading-fields (text count)
  "Return COUNT leading space fields from TEXT and the remaining text."
  (let ((start 0)
        fields)
    (dotimes (_ count)
      (let ((separator (string-match " " text start)))
        (if separator
            (progn
              (push (substring text start separator) fields)
              (setq start (1+ separator)))
          (push (substring text start) fields)
          (setq start (length text)))))
    (cons (nreverse fields)
          (if (< start (length text))
              (substring text start)
            ""))))

(defun agent-scheme-vcs--list-ref (values index &optional default)
  "Return VALUES element INDEX, or DEFAULT when out of range."
  (or (nth index values) default))

(defun agent-scheme-vcs--parse-count (text)
  "Parse signed Git ahead/behind count TEXT."
  (string-to-number
   (if (and (> (length text) 0)
            (memq (aref text 0) '(?+ ?-)))
       (substring text 1)
     text)))

(defun agent-scheme-vcs--status-char-name (char)
  "Return normalized VCS status symbol name for Git status CHAR."
  (pcase char
    ((or ?. ?\s) "unchanged")
    (?M "modified")
    (?A "added")
    (?D "deleted")
    (?T "type-changed")
    (?R "renamed")
    (?C "copied")
    (?U "unmerged")
    (?? "untracked")
    (?! "ignored")
    (_ "unknown")))

(defun agent-scheme-vcs--xy-index-status (xy)
  "Return the index-side normalized status for Git XY."
  (if (> (length xy) 0)
      (agent-scheme-vcs--status-char-name (aref xy 0))
    "unknown"))

(defun agent-scheme-vcs--xy-worktree-status (xy)
  "Return the worktree-side normalized status for Git XY."
  (if (> (length xy) 1)
      (agent-scheme-vcs--status-char-name (aref xy 1))
    "unknown"))

(defun agent-scheme-vcs--status-kind (index-status worktree-status)
  "Return status-entry kind from INDEX-STATUS and WORKTREE-STATUS."
  (cond
   ((not (equal index-status "unchanged")) index-status)
   ((not (equal worktree-status "unchanged")) worktree-status)
   (t "unchanged")))

(defun agent-scheme-vcs--submodule (text)
  "Parse porcelain v2 submodule TEXT into a datum."
  (let ((length (length text)))
    (list (agent-scheme-vcs--symbol "vcs-submodule")
          (agent-scheme-vcs--field
           "state"
           (agent-scheme-vcs--symbol
            (if (and (> length 0) (eq (aref text 0) ?S))
                "submodule"
              "none")))
          (agent-scheme-vcs--field
           "commit-changed?"
           (agent-scheme-vcs--boolean
            (and (> length 1) (eq (aref text 1) ?C))))
          (agent-scheme-vcs--field
           "tracked-changes?"
           (agent-scheme-vcs--boolean
            (and (> length 2) (eq (aref text 2) ?M))))
          (agent-scheme-vcs--field
           "untracked?"
           (agent-scheme-vcs--boolean
            (and (> length 3) (eq (aref text 3) ?U)))))))

(defun agent-scheme-vcs--conflict-type (xy)
  "Return normalized conflict type for unmerged Git XY."
  (pcase xy
    ("DD" "both-deleted")
    ("AU" "added-by-us")
    ("UD" "deleted-by-them")
    ("UA" "added-by-them")
    ("DU" "deleted-by-us")
    ("AA" "both-added")
    ("UU" "both-modified")
    (_ "unmerged")))

(defun agent-scheme-vcs--parse-status-ordinary (token)
  "Parse an ordinary porcelain v2 tracked-entry TOKEN."
  (pcase-let* ((`(,fields . ,path)
                (agent-scheme-vcs--leading-fields token 8))
               (xy (agent-scheme-vcs--list-ref fields 1 ".."))
               (submodule (agent-scheme-vcs--list-ref fields 2 "N..."))
               (index-status (agent-scheme-vcs--xy-index-status xy))
               (worktree-status (agent-scheme-vcs--xy-worktree-status xy)))
    (agent-scheme-vcs-status-entry
     (agent-scheme-vcs--status-kind index-status worktree-status)
     path
     index-status
     worktree-status
     (list
      (agent-scheme-vcs--field "xy" xy)
      (agent-scheme-vcs--field "submodule"
                               (agent-scheme-vcs--submodule submodule))
      (agent-scheme-vcs--field "head-mode"
                               (agent-scheme-vcs--list-ref
                                fields 3 agent-scheme-false))
      (agent-scheme-vcs--field "index-mode"
                               (agent-scheme-vcs--list-ref
                                fields 4 agent-scheme-false))
      (agent-scheme-vcs--field "worktree-mode"
                               (agent-scheme-vcs--list-ref
                                fields 5 agent-scheme-false))
      (agent-scheme-vcs--field "head-object"
                               (agent-scheme-vcs--list-ref
                                fields 6 agent-scheme-false))
      (agent-scheme-vcs--field "index-object"
                               (agent-scheme-vcs--list-ref
                                fields 7 agent-scheme-false))))))

(defun agent-scheme-vcs--parse-status-rename (token orig-path)
  "Parse a porcelain v2 rename/copy TOKEN and ORIG-PATH."
  (pcase-let* ((`(,fields . ,path)
                (agent-scheme-vcs--leading-fields token 9))
               (xy (agent-scheme-vcs--list-ref fields 1 ".."))
               (submodule (agent-scheme-vcs--list-ref fields 2 "N..."))
               (score-token (agent-scheme-vcs--list-ref fields 8 "R0"))
               (kind (if (string-prefix-p "C" score-token) "copied" "renamed"))
               (score (string-to-number
                       (if (> (length score-token) 1)
                           (substring score-token 1)
                         "0"))))
    (agent-scheme-vcs-status-entry
     kind
     path
     (agent-scheme-vcs--xy-index-status xy)
     (agent-scheme-vcs--xy-worktree-status xy)
     (list
      (agent-scheme-vcs--field "xy" xy)
      (agent-scheme-vcs--field "submodule"
                               (agent-scheme-vcs--submodule submodule))
      (agent-scheme-vcs--field "head-mode"
                               (agent-scheme-vcs--list-ref
                                fields 3 agent-scheme-false))
      (agent-scheme-vcs--field "index-mode"
                               (agent-scheme-vcs--list-ref
                                fields 4 agent-scheme-false))
      (agent-scheme-vcs--field "worktree-mode"
                               (agent-scheme-vcs--list-ref
                                fields 5 agent-scheme-false))
      (agent-scheme-vcs--field "head-object"
                               (agent-scheme-vcs--list-ref
                                fields 6 agent-scheme-false))
      (agent-scheme-vcs--field "index-object"
                               (agent-scheme-vcs--list-ref
                                fields 7 agent-scheme-false))
      (agent-scheme-vcs--field "orig-path" orig-path)
      (agent-scheme-vcs--field "score" (agent-scheme-vcs--integer score))))))

(defun agent-scheme-vcs--parse-status-unmerged (token)
  "Parse a porcelain v2 unmerged-entry TOKEN."
  (pcase-let* ((`(,fields . ,path)
                (agent-scheme-vcs--leading-fields token 10))
               (xy (agent-scheme-vcs--list-ref fields 1 "UU")))
    (agent-scheme-vcs-status-entry
     "conflicted"
     path
     (agent-scheme-vcs--xy-index-status xy)
     (agent-scheme-vcs--xy-worktree-status xy)
     (list
      (agent-scheme-vcs--field "xy" xy)
      (agent-scheme-vcs--field
       "submodule"
       (agent-scheme-vcs--submodule
        (agent-scheme-vcs--list-ref fields 2 "N...")))
      (agent-scheme-vcs--field "base-mode"
                               (agent-scheme-vcs--list-ref
                                fields 3 agent-scheme-false))
      (agent-scheme-vcs--field "ours-mode"
                               (agent-scheme-vcs--list-ref
                                fields 4 agent-scheme-false))
      (agent-scheme-vcs--field "theirs-mode"
                               (agent-scheme-vcs--list-ref
                                fields 5 agent-scheme-false))
      (agent-scheme-vcs--field "worktree-mode"
                               (agent-scheme-vcs--list-ref
                                fields 6 agent-scheme-false))
      (agent-scheme-vcs--field "base-object"
                               (agent-scheme-vcs--list-ref
                                fields 7 agent-scheme-false))
      (agent-scheme-vcs--field "ours-object"
                               (agent-scheme-vcs--list-ref
                                fields 8 agent-scheme-false))
      (agent-scheme-vcs--field "theirs-object"
                               (agent-scheme-vcs--list-ref
                                fields 9 agent-scheme-false))
      (agent-scheme-vcs--field
       "conflict"
       (agent-scheme-vcs-conflict-state
        (agent-scheme-vcs--conflict-type xy)
        (list path)))))))

(defun agent-scheme-vcs--parse-status-other (token kind)
  "Parse an untracked or ignored porcelain v2 TOKEN as KIND."
  (agent-scheme-vcs-status-entry
   kind
   (substring token 2)
   kind
   kind
   nil))

(defun agent-scheme-vcs--git-path-exists-p (root path)
  "Return non-nil when `git rev-parse --git-path PATH' exists under ROOT."
  (let ((result (agent-scheme-vcs--run-git root "rev-parse" "--git-path" path)))
    (and (equal (plist-get result :exit) 0)
         (file-exists-p
          (expand-file-name (string-trim (plist-get result :output)) root)))))

(defun agent-scheme-vcs--operation-state (root)
  "Return operation state for ROOT."
  (agent-scheme-vcs-operation-state
   (agent-scheme-vcs--git-path-exists-p root "MERGE_HEAD")
   (or (agent-scheme-vcs--git-path-exists-p root "rebase-merge")
       (agent-scheme-vcs--git-path-exists-p root "rebase-apply"))
   (agent-scheme-vcs--git-path-exists-p root "CHERRY_PICK_HEAD")
   (agent-scheme-vcs--git-path-exists-p root "BISECT_LOG")))

(defun agent-scheme-vcs--parse-status-output (root text)
  "Parse Git status porcelain v2 TEXT for ROOT."
  (let ((tokens (agent-scheme-vcs--split-nul text))
        oid head detached upstream
        (ahead 0)
        (behind 0)
        entries)
    (while tokens
      (let ((token (pop tokens)))
        (cond
         ((string-prefix-p "# branch.oid " token)
          (let ((value (string-remove-prefix "# branch.oid " token)))
            (setq oid (unless (equal value "(initial)") value))))
         ((string-prefix-p "# branch.head " token)
          (let ((value (string-remove-prefix "# branch.head " token)))
            (setq detached (equal value "(detached)"))
            (setq head (unless detached value))))
         ((string-prefix-p "# branch.upstream " token)
          (setq upstream (string-remove-prefix "# branch.upstream " token)))
         ((string-prefix-p "# branch.ab " token)
          (let ((counts
                 (agent-scheme-vcs--split-spaces
                  (string-remove-prefix "# branch.ab " token))))
            (setq ahead
                  (agent-scheme-vcs--parse-count
                   (agent-scheme-vcs--list-ref counts 0 "+0")))
            (setq behind
                  (agent-scheme-vcs--parse-count
                   (agent-scheme-vcs--list-ref counts 1 "-0")))))
         ((string-prefix-p "1 " token)
          (push (agent-scheme-vcs--parse-status-ordinary token) entries))
         ((string-prefix-p "2 " token)
          (let ((orig-path (or (pop tokens) "")))
            (push (agent-scheme-vcs--parse-status-rename token orig-path)
                  entries)))
         ((string-prefix-p "u " token)
          (push (agent-scheme-vcs--parse-status-unmerged token) entries))
         ((string-prefix-p "? " token)
          (push (agent-scheme-vcs--parse-status-other token "untracked")
                entries))
         ((string-prefix-p "! " token)
          (push (agent-scheme-vcs--parse-status-other token "ignored")
                entries)))))
    (agent-scheme-vcs-status
     'git
     (agent-scheme-vcs-repository 'git (directory-file-name root) root)
     (agent-scheme-vcs-branch head oid upstream ahead behind detached)
     (nreverse entries)
     (agent-scheme-vcs--operation-state root)
     (agent-scheme-vcs-outcome 'ok "observed git status porcelain v2"))))

(defun agent-scheme-vcs--empty-status (system outcome)
  "Return an empty status datum for SYSTEM with OUTCOME."
  (agent-scheme-vcs-status
   system
   agent-scheme-false
   agent-scheme-false
   nil
   (agent-scheme-vcs-operation-state nil nil nil nil)
   outcome))

(defun agent-scheme-vcs-root-datum (&optional options)
  "Return the current repository root as a VCS repository datum or outcome."
  (let ((info (agent-scheme-vcs--root-info options)))
    (if (eq (plist-get info :status) 'ok)
        (let ((root (plist-get info :root)))
          (agent-scheme-vcs-repository 'git (directory-file-name root) root))
      (plist-get info :outcome))))

(defun agent-scheme-vcs-status-datum (&optional options)
  "Return current Git status as a shared VCS status datum."
  (let ((info (agent-scheme-vcs--root-info options)))
    (pcase (plist-get info :status)
      ('ok
       (let* ((root (plist-get info :root))
              (arguments
               (append
                '("status" "--porcelain=v2" "-z" "--branch"
                  "--untracked-files=all")
                (when (agent-scheme-vcs--scheme-true-p
                       (agent-scheme-vcs--option-value
                        options "include-ignored?"))
                  '("--ignored=matching"))))
              (result (apply #'agent-scheme-vcs--run-git root arguments)))
         (if (equal (plist-get result :exit) 0)
             (agent-scheme-vcs--parse-status-output
              root (plist-get result :output))
           (agent-scheme-vcs--empty-status
            'git
            (agent-scheme-vcs-outcome
             'permission-denied
             (string-trim (plist-get result :output)))))))
      ('unsupported-vcs
       (agent-scheme-vcs--empty-status
        'unsupported
        (plist-get info :outcome)))
      ('git-not-found
       (agent-scheme-vcs--empty-status 'git (plist-get info :outcome)))
      (_
       (agent-scheme-vcs--empty-status 'none (plist-get info :outcome))))))

(defun agent-scheme-vcs-branch-datum (&optional options)
  "Return the current branch datum or a VCS outcome outside repositories."
  (let ((status (agent-scheme-vcs-status-datum options)))
    (if (agent-scheme-vcs--record-p status "vcs-status")
        (let ((outcome (agent-scheme-vcs-field-value status "outcome")))
          (if (equal (agent-scheme--symbol-name
                      (agent-scheme-vcs-field-value outcome "status"))
                     "ok")
              (agent-scheme-vcs-field-value status "branch")
            outcome))
      status)))

(defun agent-scheme-vcs--raw-status-kind (status-token)
  "Return normalized raw diff status from STATUS-TOKEN."
  (if (> (length status-token) 0)
      (agent-scheme-vcs--status-char-name (aref status-token 0))
    "unknown"))

(defun agent-scheme-vcs--raw-status-score (status-token)
  "Return raw diff score suffix from STATUS-TOKEN, or nil."
  (when (> (length status-token) 1)
    (string-to-number (substring status-token 1))))

(defun agent-scheme-vcs--parse-raw-diff-record (metadata rest)
  "Parse raw diff METADATA and following path tokens REST."
  (let* ((fields (agent-scheme-vcs--split-spaces metadata))
         (old-mode-token (agent-scheme-vcs--list-ref fields 0 ":000000"))
         (new-mode (agent-scheme-vcs--list-ref fields 1 "000000"))
         (old-object (agent-scheme-vcs--list-ref fields 2 "0000000"))
         (new-object (agent-scheme-vcs--list-ref fields 3 "0000000"))
         (status-token (agent-scheme-vcs--list-ref fields 4 "X"))
         (old-mode (if (string-prefix-p ":" old-mode-token)
                       (substring old-mode-token 1)
                     old-mode-token))
         (status (agent-scheme-vcs--raw-status-kind status-token))
         (score (agent-scheme-vcs--raw-status-score status-token)))
    (if (member status '("renamed" "copied"))
        (cons
         (agent-scheme-vcs-diff-file
          status
          (agent-scheme-vcs--list-ref rest 1 "")
          (agent-scheme-vcs--list-ref rest 0 "")
          old-mode
          new-mode
          old-object
          new-object
          score)
         (nthcdr (min 2 (length rest)) rest))
      (cons
       (agent-scheme-vcs-diff-file
        status
        (agent-scheme-vcs--list-ref rest 0 "")
        nil
        old-mode
        new-mode
        old-object
        new-object
        score)
       (nthcdr (min 1 (length rest)) rest)))))

(defun agent-scheme-vcs--parse-raw-diff (text)
  "Parse Git raw diff -z TEXT into diff file records."
  (let ((tokens (agent-scheme-vcs--split-nul text))
        files)
    (while tokens
      (let ((token (pop tokens)))
        (when (string-prefix-p ":" token)
          (let ((parsed (agent-scheme-vcs--parse-raw-diff-record token tokens)))
            (push (car parsed) files)
            (setq tokens (cdr parsed))))))
    (nreverse files)))

(defun agent-scheme-vcs-diff-datum (&optional options)
  "Return current Git raw diff summary as a VCS diff datum."
  (let ((info (agent-scheme-vcs--root-info options)))
    (if (eq (plist-get info :status) 'ok)
        (let* ((root (plist-get info :root))
               (arguments
                (append
                 '("diff" "--raw" "-z")
                 (when (or (agent-scheme-vcs--scheme-true-p
                            (agent-scheme-vcs--option-value
                             options "cached?"))
                           (agent-scheme-vcs--scheme-true-p
                            (agent-scheme-vcs--option-value
                             options "staged?")))
                   '("--cached"))))
               (result (apply #'agent-scheme-vcs--run-git root arguments)))
          (agent-scheme-vcs-diff-summary
           'git
           (if (equal (plist-get result :exit) 0)
               (agent-scheme-vcs--parse-raw-diff (plist-get result :output))
             nil)))
      (agent-scheme-vcs-diff-summary
       (if (eq (plist-get info :status) 'unsupported-vcs)
           'unsupported
         'none)
       nil))))

(defun agent-scheme-vcs--split-log-record (record)
  "Split one formatted Git log RECORD into fields."
  (split-string record "\x1f"))

(defun agent-scheme-vcs--parse-commit-record (record)
  "Parse one formatted Git log RECORD."
  (let* ((fields (agent-scheme-vcs--split-log-record record))
         (oid (agent-scheme-vcs--list-ref fields 0 ""))
         (parents-text (agent-scheme-vcs--list-ref fields 1 ""))
         (subject (agent-scheme-vcs--list-ref fields 2 ""))
         (author (agent-scheme-vcs--list-ref fields 3 ""))
         (timestamp (agent-scheme-vcs--list-ref fields 4 "")))
    (agent-scheme-vcs-commit-summary
     oid
     (if (string-empty-p parents-text)
         nil
       (split-string parents-text " " t))
     subject
     author
     timestamp)))

(defun agent-scheme-vcs-recent-commits-datum (count &optional options)
  "Return up to COUNT recent commit summary datums."
  (let ((info (agent-scheme-vcs--root-info options)))
    (if (eq (plist-get info :status) 'ok)
        (let* ((root (plist-get info :root))
               (limit (max 0 count))
               (result
                (agent-scheme-vcs--run-git
                 root
                 "log"
                 "-n" (number-to-string limit)
                 "--pretty=format:%H%x1f%P%x1f%s%x1f%an <%ae>%x1f%cI%x1e")))
          (if (equal (plist-get result :exit) 0)
              (mapcar #'agent-scheme-vcs--parse-commit-record
                      (split-string (plist-get result :output) "\x1e" t))
            nil))
      nil)))

(provide 'agent-scheme-vcs)

;;; agent-scheme-vcs.el ends here
