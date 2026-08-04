;;; consent-vcs.el -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

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
(require 'consent-audit)
(require 'consent-result)
(require 'consent-runtime)

(defcustom consent-vcs-git-command "git"
  "Git executable used by the read-only Emacs VCS adapter."
  :type 'string
  :group 'consent)

(defvar consent--next-vcs-capability-request-number 0
  "Next numeric suffix for generated VCS capability request ids.")

(defun consent-vcs--symbol (name)
  "Return NAME as an Consent Scheme symbol datum."
  (consent--syntax-symbol
   (cond
    ((consent-symbol-p name)
     (consent-symbol-name name))
    ((symbolp name)
     (symbol-name name))
    ((stringp name)
     name)
    (t
     (format "%S" name)))))

(defun consent-vcs--name (value)
  "Return VALUE as a plain symbol/string name, or nil."
  (cond
   ((consent-symbol-p value)
    (consent-symbol-name value))
   ((symbolp value)
    (symbol-name value))
   ((stringp value)
    value)
   (t nil)))

(defun consent-vcs--field (name &rest values)
  "Return a Scheme-readable VCS field named NAME with VALUES."
  (cons (consent-vcs--symbol name) values))

(defun consent-vcs--integer (value)
  "Return VALUE as an exact Consent Scheme integer datum."
  (consent--make-number
   (number-to-string value) 'exact 10 'integer value))

(defun consent-vcs--boolean (value)
  "Return VALUE as an Consent Scheme boolean datum."
  (if value consent-true consent-false))

(defun consent-vcs--false-p (value)
  "Return non-nil when VALUE represents Scheme false or absence."
  (or (null value) (eq value consent-false)))

(defun consent-vcs--maybe-string (value)
  "Return VALUE as a plain string datum, or #f when VALUE is nil."
  (if value (substring-no-properties value) consent-false))

(defun consent-vcs--record-p (datum tag)
  "Return non-nil when DATUM is a Scheme-readable record tagged TAG."
  (and (consp datum)
       (equal (consent--symbol-name (car datum)) tag)))

(defun consent-vcs-field-value (record name &optional default)
  "Return field NAME from RECORD, or DEFAULT when absent."
  (let ((entry
         (seq-find
          (lambda (field)
            (and (consp field)
                 (equal (consent--symbol-name (car field)) name)))
          (cdr-safe record))))
    (if entry
        (cadr entry)
      default)))

(defun consent-vcs-outcome (status message)
  "Return a VCS outcome datum with STATUS and MESSAGE."
  (list (consent-vcs--symbol "vcs-outcome")
        (consent-vcs--field "status" (consent-vcs--symbol status))
        (consent-vcs--field "message" message)))

(defconst consent-vcs--read-only-operations
  '("status" "refs" "branches" "commit-summary" "diff-summary" "remotes"
    "operation-state")
  "Read-only VCS operation names.")

(defconst consent-vcs--mutating-operations
  '("stage" "unstage" "commit" "branch-create" "branch-delete" "checkout"
    "switch" "fetch" "pull" "push" "merge" "rebase" "cherry-pick" "revert"
    "reset")
  "Mutating VCS operation names.")

(defconst consent-vcs--remote-operations
  '("fetch" "pull" "push")
  "VCS operation names that communicate with remotes.")

(defun consent-vcs--read-only-operation-p (operation)
  "Return non-nil when OPERATION is a read-only VCS operation."
  (member (consent-vcs--name operation)
          consent-vcs--read-only-operations))

(defun consent-vcs--mutating-operation-p (operation)
  "Return non-nil when OPERATION is a mutating VCS operation."
  (member (consent-vcs--name operation)
          consent-vcs--mutating-operations))

(defun consent-vcs--remote-operation-p (operation)
  "Return non-nil when OPERATION communicates with a remote."
  (member (consent-vcs--name operation)
          consent-vcs--remote-operations))

(defun consent-vcs--operation-authority (operation)
  "Return the authority family required for OPERATION."
  (cond
   ((consent-vcs--read-only-operation-p operation) "read-only-observation")
   ((consent-vcs--remote-operation-p operation) "remote-mutation")
   ((consent-vcs--mutating-operation-p operation) "repository-mutation")
   (t "unknown")))

(defun consent-vcs--request-id ()
  "Return a fresh VCS capability request id."
  (consent-vcs--symbol
   (format "req-vcs-%d"
           (cl-incf consent--next-vcs-capability-request-number))))

(defun consent-vcs-capability-request
    (id operation authority arguments)
  "Return a VCS capability request datum."
  (list (consent-vcs--symbol "vcs-capability-request")
        (consent-vcs--field "id" id)
        (consent-vcs--field "operation"
                                 (consent-vcs--symbol operation))
        (consent-vcs--field "authority"
                                 (consent-vcs--symbol authority))
        (consent-vcs--field "arguments" arguments)
        (consent-vcs--field
         "required-authority"
         (consent-vcs--symbol
          (consent-vcs--operation-authority operation)))
        (consent-vcs--field
         "remote?" (consent-vcs--boolean
                    (consent-vcs--remote-operation-p operation)))
        (consent-vcs--field
         "mutating?" (consent-vcs--boolean
                      (consent-vcs--mutating-operation-p operation)))))

(defun consent-vcs-capability-result (id status value)
  "Return a VCS capability result datum."
  (list (consent-vcs--symbol "vcs-capability-result")
        (consent-vcs--field "id" id)
        (consent-vcs--field "status" (consent-vcs--symbol status))
        (consent-vcs--field "value" value)))

(defun consent-vcs-capability-decision
    (request status grant approval reason)
  "Return a VCS capability decision datum."
  (let* ((operation (consent-vcs-field-value request "operation"))
         (authority (consent-vcs--operation-authority operation)))
    (list
     (consent-vcs--symbol "vcs-capability-decision")
     (consent-vcs--field
      "id" (consent-vcs-field-value request "id"))
     (consent-vcs--field "operation" operation)
     (consent-vcs--field "authority"
                              (consent-vcs--symbol authority))
     (consent-vcs--field
      "requested-authority"
      (consent-vcs-field-value request "authority"))
     (consent-vcs--field "status" (consent-vcs--symbol status))
     (consent-vcs--field
      "grant" (if grant
                  (consent-vcs-field-value grant "id")
                consent-false))
     (consent-vcs--field
      "approval" (if approval
                     (consent-vcs-field-value approval "id")
                   consent-false))
     (consent-vcs--field "reason" reason)
     (consent-vcs--field
      "remote?" (consent-vcs--boolean
                 (consent-vcs--remote-operation-p operation))))))

(defun consent-vcs-capability-decision-status (decision)
  "Return DECISION's status name."
  (consent-vcs--name
   (consent-vcs-field-value decision "status")))

(defun consent-vcs--result-outcome-status (result)
  "Return RESULT's VCS outcome status name, or nil."
  (let ((value (consent-vcs-field-value result "value")))
    (when (consent-vcs--record-p value "vcs-outcome")
      (consent-vcs--name
       (consent-vcs-field-value value "status")))))

(defun consent-vcs-capability-audit (request decision result)
  "Return a VCS capability audit datum."
  (let ((operation (consent-vcs-field-value request "operation")))
    (list (consent-vcs--symbol "vcs-capability-audit")
          (consent-vcs--field "event"
                                   (consent-vcs--symbol
                                    "vcs-capability-audit"))
          (consent-vcs--field
           "id" (consent-vcs-field-value request "id"))
          (consent-vcs--field "operation" operation)
          (consent-vcs--field
           "authority"
           (consent-vcs--symbol
            (consent-vcs--operation-authority operation)))
          (consent-vcs--field
           "remote?" (consent-vcs--boolean
                      (consent-vcs--remote-operation-p operation)))
          (consent-vcs--field
           "remote"
           (or (consent-vcs--request-argument request "remote")
               consent-false))
          (consent-vcs--field
           "decision"
           (consent-vcs-field-value decision "status"))
          (consent-vcs--field
           "result" (consent-vcs-field-value result "status"))
          (consent-vcs--field
           "outcome"
           (or (and-let* ((status (consent-vcs--result-outcome-status
                                   result)))
                 (consent-vcs--symbol status))
               consent-false)))))

(defun consent-vcs-repository (system root identity)
  "Return a repository identity/root datum."
  (list (consent-vcs--symbol "vcs-repository")
        (consent-vcs--field "system" (consent-vcs--symbol system))
        (consent-vcs--field "root" (consent-vcs--maybe-string root))
        (consent-vcs--field "identity"
                                 (consent-vcs--maybe-string identity))))

(defun consent-vcs-branch
    (head oid upstream ahead behind detached)
  "Return a branch or detached-head datum."
  (list (consent-vcs--symbol "vcs-branch")
        (consent-vcs--field "head" (consent-vcs--maybe-string head))
        (consent-vcs--field "oid" (consent-vcs--maybe-string oid))
        (consent-vcs--field "upstream"
                                 (consent-vcs--maybe-string upstream))
        (consent-vcs--field "ahead" (consent-vcs--integer ahead))
        (consent-vcs--field "behind" (consent-vcs--integer behind))
        (consent-vcs--field "detached?"
                                 (consent-vcs--boolean detached))))

(defun consent-vcs-operation-state (merge rebase cherry-pick bisect)
  "Return merge/rebase/cherry-pick/bisect state as Scheme data."
  (list (consent-vcs--symbol "vcs-operation-state")
        (consent-vcs--field "merge" (consent-vcs--boolean merge))
        (consent-vcs--field "rebase" (consent-vcs--boolean rebase))
        (consent-vcs--field "cherry-pick"
                                 (consent-vcs--boolean cherry-pick))
        (consent-vcs--field "bisect" (consent-vcs--boolean bisect))))

(defun consent-vcs-conflict-state (type paths)
  "Return a conflict state datum for TYPE and PATHS."
  (list (consent-vcs--symbol "vcs-conflict-state")
        (consent-vcs--field "type" (consent-vcs--symbol type))
        (consent-vcs--field "paths" paths)))

(defun consent-vcs-status
    (system repository branch entries operation-state outcome)
  "Return a repository status snapshot datum."
  (list (consent-vcs--symbol "vcs-status")
        (consent-vcs--field "system" (consent-vcs--symbol system))
        (consent-vcs--field "repository" repository)
        (consent-vcs--field "branch" branch)
        (consent-vcs--field "entries" entries)
        (consent-vcs--field "operation-state" operation-state)
        (consent-vcs--field "outcome" outcome)))

(defun consent-vcs-status-entry
    (kind path index-status worktree-status details)
  "Return a worktree/index status entry datum with DETAILS fields."
  (append
   (list (consent-vcs--symbol "vcs-status-entry")
         (consent-vcs--field "kind" (consent-vcs--symbol kind))
         (consent-vcs--field "path" path)
         (consent-vcs--field "index-status"
                                  (consent-vcs--symbol index-status))
         (consent-vcs--field "worktree-status"
                                  (consent-vcs--symbol worktree-status)))
   details))

(defun consent-vcs-diff-summary (system files)
  "Return a file-level VCS diff summary datum."
  (list (consent-vcs--symbol "vcs-diff-summary")
        (consent-vcs--field "system" (consent-vcs--symbol system))
        (consent-vcs--field "files" files)))

(defun consent-vcs-diff-file
    (status path orig-path old-mode new-mode old-object new-object score)
  "Return one file-level raw diff summary datum."
  (list (consent-vcs--symbol "vcs-diff-file")
        (consent-vcs--field "status" (consent-vcs--symbol status))
        (consent-vcs--field "path" path)
        (consent-vcs--field "orig-path"
                                 (consent-vcs--maybe-string orig-path))
        (consent-vcs--field "old-mode" old-mode)
        (consent-vcs--field "new-mode" new-mode)
        (consent-vcs--field "old-object" old-object)
        (consent-vcs--field "new-object" new-object)
        (consent-vcs--field "score"
                                 (if score
                                     (consent-vcs--integer score)
                                   consent-false))))

(defun consent-vcs-commit-summary
    (oid parents subject author timestamp)
  "Return a compact commit summary datum."
  (list (consent-vcs--symbol "vcs-commit-summary")
        (consent-vcs--field "oid" oid)
        (consent-vcs--field "parents" parents)
        (consent-vcs--field "subject" subject)
        (consent-vcs--field "author" author)
        (consent-vcs--field "timestamp" timestamp)))

(defun consent-vcs--options-list (options description)
  "Return OPTIONS as a proper list for DESCRIPTION."
  (if (null options)
      nil
    (consent--proper-list-elements options description)))

(defun consent-vcs--option-value (options name)
  "Return option NAME from OPTIONS, or nil when absent."
  (when-let ((entry
              (seq-find
               (lambda (field)
                 (and (consp field)
                      (equal (consent--symbol-name (car field)) name)))
               (consent-vcs--options-list options "VCS options"))))
    (cadr entry)))

(defun consent-vcs--option-values (options name)
  "Return all values for option NAME from OPTIONS."
  (if-let ((entry
            (seq-find
             (lambda (field)
               (and (consp field)
                    (equal (consent--symbol-name (car field)) name)))
             (consent-vcs--options-list options "VCS options"))))
      (cdr entry)
    nil))

(defun consent-vcs--scheme-true-p (value)
  "Return non-nil when VALUE is Scheme truth."
  (not (or (null value) (eq value consent-false))))

(defun consent-vcs--option-datum-list (options name)
  "Return option NAME as a proper datum list."
  (let ((values (consent-vcs--option-values options name)))
    (cond
     ((null values) nil)
     ((and (= (length values) 1)
           (listp (car values))
           (not (consent-symbol-p (car values))))
      (consent--proper-list-elements
       (car values) (format "VCS option %s" name)))
     (t values))))

(defun consent-vcs--option-string-list (options name)
  "Return option NAME as a list of strings."
  (mapcar
   (lambda (value)
     (unless (stringp value)
       (consent--eval-error
        "VCS option %s expected strings, got %s"
        name
        (consent-value->external value)))
     (substring-no-properties value))
   (consent-vcs--option-datum-list options name)))

(defun consent-vcs--option-string (options name)
  "Return string option NAME from OPTIONS, or nil when absent."
  (when-let ((value (consent-vcs--option-value options name)))
    (unless (stringp value)
      (consent--eval-error
       "VCS option %s expected a string, got %s"
       name
       (consent-value->external value)))
    (substring-no-properties value)))

(defun consent-vcs--request-argument (request name)
  "Return REQUEST argument NAME, or nil."
  (when-let ((arguments (consent-vcs-field-value request "arguments")))
    (when-let ((entry
                (seq-find
                 (lambda (field)
                   (and (consp field)
                        (equal (consent-vcs--name (car field)) name)))
                 arguments)))
      (cadr entry))))

(defun consent-vcs--operation-covered-p (operation operations)
  "Return non-nil when OPERATIONS covers OPERATION."
  (let ((operation-name (consent-vcs--name operation)))
    (cond
     ((equal (consent-vcs--name operations) "all") t)
     ((listp operations)
      (seq-some
       (lambda (candidate)
         (or (equal (consent-vcs--name candidate) operation-name)
             (equal (consent-vcs--name candidate) "all")))
       operations))
     (t
      (equal (consent-vcs--name operations) operation-name)))))

(defun consent-vcs--scope-matches-p (scope value)
  "Return non-nil when SCOPE matches VALUE."
  (or (consent-vcs--false-p scope)
      (equal (consent-vcs--name scope) "all")
      (equal scope value)
      (and (consent-vcs--name scope)
           (equal (consent-vcs--name scope)
                  (consent-vcs--name value)))))

(defun consent-vcs--grant-allows-p (request grant)
  "Return non-nil when VCS GRANT authorizes REQUEST."
  (let* ((operation (consent-vcs-field-value request "operation"))
         (required-authority
          (consent-vcs--operation-authority operation))
         (grant-authority
          (consent-vcs--name
           (consent-vcs-field-value grant "authority"))))
    (and (or (equal grant-authority required-authority)
             (equal grant-authority "all"))
         (consent-vcs--operation-covered-p
          operation
          (consent-vcs-field-value grant "operations"))
         (consent-vcs--scope-matches-p
          (consent-vcs-field-value grant "repository")
          (consent-vcs--request-argument request "repository"))
         (consent-vcs--scope-matches-p
          (consent-vcs-field-value grant "remote")
          (consent-vcs--request-argument request "remote")))))

(defun consent-vcs--find-grant (request grants)
  "Return the first VCS grant in GRANTS that authorizes REQUEST."
  (seq-find
   (lambda (grant)
     (and (consent-vcs--record-p grant "vcs-capability-grant")
          (consent-vcs--grant-allows-p request grant)))
   grants))

(defun consent-vcs--approval-allows-p (request approval)
  "Return non-nil when APPROVAL authorizes REQUEST."
  (and (consent-vcs--record-p approval "vcs-approval-decision")
       (equal (consent-vcs-field-value request "id")
              (consent-vcs-field-value approval "request-id"))
       (equal (consent-vcs--name
               (consent-vcs-field-value approval "status"))
              "approved")))

(defun consent-vcs--find-approval (request approvals)
  "Return the first VCS approval in APPROVALS that authorizes REQUEST."
  (seq-find
   (lambda (approval)
     (consent-vcs--approval-allows-p request approval))
   approvals))

(defun consent-vcs-authorize-capability-request
    (request grants approvals)
  "Return a fail-closed VCS authorization decision for REQUEST."
  (let* ((operation (consent-vcs-field-value request "operation"))
         (operation-name (consent-vcs--name operation))
         (required-authority
          (consent-vcs--operation-authority operation-name))
         (requested-authority
          (consent-vcs--name
           (consent-vcs-field-value request "authority"))))
    (cond
     ((consent-vcs--read-only-operation-p operation-name)
      (consent-vcs-capability-decision
       request 'approved nil nil "read-only observation"))
     ((not (consent-vcs--mutating-operation-p operation-name))
      (consent-vcs-capability-decision
       request 'denied nil nil "unknown VCS operation"))
     ((not (equal requested-authority required-authority))
      (consent-vcs-capability-decision
       request
       'denied
       nil
       nil
       "requested VCS authority does not match operation"))
     (t
      (if-let ((grant (consent-vcs--find-grant request grants)))
          (consent-vcs-capability-decision
           request 'approved grant nil "authorized by VCS grant")
        (if-let ((approval (consent-vcs--find-approval
                            request approvals)))
            (consent-vcs-capability-decision
             request 'approved nil approval "authorized by VCS approval")
          (consent-vcs-capability-decision
           request
           'denied
           nil
           nil
           "missing VCS mutation grant or approval")))))))

(defun consent-vcs--working-directory (&optional options)
  "Return the directory used for a VCS observation."
  (file-name-as-directory
   (expand-file-name
    (or (consent-vcs--option-string options "root")
        (consent-vcs--option-string options "path")
        (when-let ((project (project-current nil)))
          (project-root project))
        default-directory))))

(defun consent-vcs--git-executable ()
  "Return the configured Git executable, or nil when unavailable."
  (executable-find consent-vcs-git-command))

(defun consent-vcs--run-git (directory &rest arguments)
  "Run Git in DIRECTORY with ARGUMENTS.
Return a plist with `:exit' and `:output', or `:status' when Git is missing."
  (if-let ((git (consent-vcs--git-executable)))
      (let ((default-directory directory))
        (with-temp-buffer
          (let ((exit (apply #'process-file
                             git nil (current-buffer) nil arguments)))
            (list :exit exit :output (buffer-string)))))
    (list :status 'git-not-found
          :output ""
          :message "Git executable was not found.")))

(defun consent-vcs--vc-backend (directory)
  "Return the VC backend responsible for DIRECTORY, or nil."
  (ignore-errors
    (vc-responsible-backend directory)))

(defun consent-vcs--unsupported-backend-outcome (backend)
  "Return an unsupported-VCS outcome for BACKEND."
  (consent-vcs-outcome
   'unsupported-vcs
   (format "Unsupported VCS backend: %s" backend)))

(defun consent-vcs--root-info (&optional options)
  "Return root resolution info for OPTIONS."
  (let* ((directory (consent-vcs--working-directory options))
         (backend (consent-vcs--vc-backend directory)))
    (cond
     ((and backend (not (eq backend 'Git)))
      (list :status 'unsupported-vcs
            :directory directory
            :backend backend
            :outcome (consent-vcs--unsupported-backend-outcome backend)))
     (t
      (let ((result
             (consent-vcs--run-git
              directory "rev-parse" "--show-toplevel")))
        (cond
         ((plist-get result :status)
          (list :status (plist-get result :status)
                :directory directory
                :outcome (consent-vcs-outcome
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
                :outcome (consent-vcs-outcome
                          'no-vcs
                          "No repository found.")))))))))

(defun consent-vcs--split-nul (text)
  "Split NUL-delimited Git machine-format TEXT."
  (split-string text "\0" t))

(defun consent-vcs--split-spaces (text)
  "Split TEXT into non-empty space-separated fields."
  (split-string text " " t))

(defun consent-vcs--leading-fields (text count)
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

(defun consent-vcs--list-ref (values index &optional default)
  "Return VALUES element INDEX, or DEFAULT when out of range."
  (or (nth index values) default))

(defun consent-vcs--parse-count (text)
  "Parse signed Git ahead/behind count TEXT."
  (string-to-number
   (if (and (> (length text) 0)
            (memq (aref text 0) '(?+ ?-)))
       (substring text 1)
     text)))

(defun consent-vcs--status-char-name (char)
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

(defun consent-vcs--xy-index-status (xy)
  "Return the index-side normalized status for Git XY."
  (if (> (length xy) 0)
      (consent-vcs--status-char-name (aref xy 0))
    "unknown"))

(defun consent-vcs--xy-worktree-status (xy)
  "Return the worktree-side normalized status for Git XY."
  (if (> (length xy) 1)
      (consent-vcs--status-char-name (aref xy 1))
    "unknown"))

(defun consent-vcs--status-kind (index-status worktree-status)
  "Return status-entry kind from INDEX-STATUS and WORKTREE-STATUS."
  (cond
   ((not (equal index-status "unchanged")) index-status)
   ((not (equal worktree-status "unchanged")) worktree-status)
   (t "unchanged")))

(defun consent-vcs--submodule (text)
  "Parse porcelain v2 submodule TEXT into a datum."
  (let ((length (length text)))
    (list (consent-vcs--symbol "vcs-submodule")
          (consent-vcs--field
           "state"
           (consent-vcs--symbol
            (if (and (> length 0) (eq (aref text 0) ?S))
                "submodule"
              "none")))
          (consent-vcs--field
           "commit-changed?"
           (consent-vcs--boolean
            (and (> length 1) (eq (aref text 1) ?C))))
          (consent-vcs--field
           "tracked-changes?"
           (consent-vcs--boolean
            (and (> length 2) (eq (aref text 2) ?M))))
          (consent-vcs--field
           "untracked?"
           (consent-vcs--boolean
            (and (> length 3) (eq (aref text 3) ?U)))))))

(defun consent-vcs--conflict-type (xy)
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

(defun consent-vcs--parse-status-ordinary (token)
  "Parse an ordinary porcelain v2 tracked-entry TOKEN."
  (pcase-let* ((`(,fields . ,path)
                (consent-vcs--leading-fields token 8))
               (xy (consent-vcs--list-ref fields 1 ".."))
               (submodule (consent-vcs--list-ref fields 2 "N..."))
               (index-status (consent-vcs--xy-index-status xy))
               (worktree-status (consent-vcs--xy-worktree-status xy)))
    (consent-vcs-status-entry
     (consent-vcs--status-kind index-status worktree-status)
     path
     index-status
     worktree-status
     (list
      (consent-vcs--field "xy" xy)
      (consent-vcs--field "submodule"
                               (consent-vcs--submodule submodule))
      (consent-vcs--field "head-mode"
                               (consent-vcs--list-ref
                                fields 3 consent-false))
      (consent-vcs--field "index-mode"
                               (consent-vcs--list-ref
                                fields 4 consent-false))
      (consent-vcs--field "worktree-mode"
                               (consent-vcs--list-ref
                                fields 5 consent-false))
      (consent-vcs--field "head-object"
                               (consent-vcs--list-ref
                                fields 6 consent-false))
      (consent-vcs--field "index-object"
                               (consent-vcs--list-ref
                                fields 7 consent-false))))))

(defun consent-vcs--parse-status-rename (token orig-path)
  "Parse a porcelain v2 rename/copy TOKEN and ORIG-PATH."
  (pcase-let* ((`(,fields . ,path)
                (consent-vcs--leading-fields token 9))
               (xy (consent-vcs--list-ref fields 1 ".."))
               (submodule (consent-vcs--list-ref fields 2 "N..."))
               (score-token (consent-vcs--list-ref fields 8 "R0"))
               (kind (if (string-prefix-p "C" score-token) "copied" "renamed"))
               (score (string-to-number
                       (if (> (length score-token) 1)
                           (substring score-token 1)
                         "0"))))
    (consent-vcs-status-entry
     kind
     path
     (consent-vcs--xy-index-status xy)
     (consent-vcs--xy-worktree-status xy)
     (list
      (consent-vcs--field "xy" xy)
      (consent-vcs--field "submodule"
                               (consent-vcs--submodule submodule))
      (consent-vcs--field "head-mode"
                               (consent-vcs--list-ref
                                fields 3 consent-false))
      (consent-vcs--field "index-mode"
                               (consent-vcs--list-ref
                                fields 4 consent-false))
      (consent-vcs--field "worktree-mode"
                               (consent-vcs--list-ref
                                fields 5 consent-false))
      (consent-vcs--field "head-object"
                               (consent-vcs--list-ref
                                fields 6 consent-false))
      (consent-vcs--field "index-object"
                               (consent-vcs--list-ref
                                fields 7 consent-false))
      (consent-vcs--field "orig-path" orig-path)
      (consent-vcs--field "score" (consent-vcs--integer score))))))

(defun consent-vcs--parse-status-unmerged (token)
  "Parse a porcelain v2 unmerged-entry TOKEN."
  (pcase-let* ((`(,fields . ,path)
                (consent-vcs--leading-fields token 10))
               (xy (consent-vcs--list-ref fields 1 "UU")))
    (consent-vcs-status-entry
     "conflicted"
     path
     (consent-vcs--xy-index-status xy)
     (consent-vcs--xy-worktree-status xy)
     (list
      (consent-vcs--field "xy" xy)
      (consent-vcs--field
       "submodule"
       (consent-vcs--submodule
        (consent-vcs--list-ref fields 2 "N...")))
      (consent-vcs--field "base-mode"
                               (consent-vcs--list-ref
                                fields 3 consent-false))
      (consent-vcs--field "ours-mode"
                               (consent-vcs--list-ref
                                fields 4 consent-false))
      (consent-vcs--field "theirs-mode"
                               (consent-vcs--list-ref
                                fields 5 consent-false))
      (consent-vcs--field "worktree-mode"
                               (consent-vcs--list-ref
                                fields 6 consent-false))
      (consent-vcs--field "base-object"
                               (consent-vcs--list-ref
                                fields 7 consent-false))
      (consent-vcs--field "ours-object"
                               (consent-vcs--list-ref
                                fields 8 consent-false))
      (consent-vcs--field "theirs-object"
                               (consent-vcs--list-ref
                                fields 9 consent-false))
      (consent-vcs--field
       "conflict"
       (consent-vcs-conflict-state
        (consent-vcs--conflict-type xy)
        (list path)))))))

(defun consent-vcs--parse-status-other (token kind)
  "Parse an untracked or ignored porcelain v2 TOKEN as KIND."
  (consent-vcs-status-entry
   kind
   (substring token 2)
   kind
   kind
   nil))

(defun consent-vcs--git-path-exists-p (root path)
  "Return non-nil when `git rev-parse --git-path PATH' exists under ROOT."
  (let ((result (consent-vcs--run-git root "rev-parse" "--git-path" path)))
    (and (equal (plist-get result :exit) 0)
         (file-exists-p
          (expand-file-name (string-trim (plist-get result :output)) root)))))

(defun consent-vcs--operation-state (root)
  "Return operation state for ROOT."
  (consent-vcs-operation-state
   (consent-vcs--git-path-exists-p root "MERGE_HEAD")
   (or (consent-vcs--git-path-exists-p root "rebase-merge")
       (consent-vcs--git-path-exists-p root "rebase-apply"))
   (consent-vcs--git-path-exists-p root "CHERRY_PICK_HEAD")
   (consent-vcs--git-path-exists-p root "BISECT_LOG")))

(defun consent-vcs--parse-status-output (root text)
  "Parse Git status porcelain v2 TEXT for ROOT."
  (let ((tokens (consent-vcs--split-nul text))
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
                 (consent-vcs--split-spaces
                  (string-remove-prefix "# branch.ab " token))))
            (setq ahead
                  (consent-vcs--parse-count
                   (consent-vcs--list-ref counts 0 "+0")))
            (setq behind
                  (consent-vcs--parse-count
                   (consent-vcs--list-ref counts 1 "-0")))))
         ((string-prefix-p "1 " token)
          (push (consent-vcs--parse-status-ordinary token) entries))
         ((string-prefix-p "2 " token)
          (let ((orig-path (or (pop tokens) "")))
            (push (consent-vcs--parse-status-rename token orig-path)
                  entries)))
         ((string-prefix-p "u " token)
          (push (consent-vcs--parse-status-unmerged token) entries))
         ((string-prefix-p "? " token)
          (push (consent-vcs--parse-status-other token "untracked")
                entries))
         ((string-prefix-p "! " token)
          (push (consent-vcs--parse-status-other token "ignored")
                entries)))))
    (consent-vcs-status
     'git
     (consent-vcs-repository 'git (directory-file-name root) root)
     (consent-vcs-branch head oid upstream ahead behind detached)
     (nreverse entries)
     (consent-vcs--operation-state root)
     (consent-vcs-outcome 'ok "observed git status porcelain v2"))))

(defun consent-vcs--empty-status (system outcome)
  "Return an empty status datum for SYSTEM with OUTCOME."
  (consent-vcs-status
   system
   consent-false
   consent-false
   nil
   (consent-vcs-operation-state nil nil nil nil)
   outcome))

(defun consent-vcs-root-datum (&optional options)
  "Return the current repository root as a VCS repository datum or outcome."
  (let ((info (consent-vcs--root-info options)))
    (if (eq (plist-get info :status) 'ok)
        (let ((root (plist-get info :root)))
          (consent-vcs-repository 'git (directory-file-name root) root))
      (plist-get info :outcome))))

(defun consent-vcs-status-datum (&optional options)
  "Return current Git status as a shared VCS status datum."
  (let ((info (consent-vcs--root-info options)))
    (pcase (plist-get info :status)
      ('ok
       (let* ((root (plist-get info :root))
              (arguments
               (append
                '("status" "--porcelain=v2" "-z" "--branch"
                  "--untracked-files=all")
                (when (consent-vcs--scheme-true-p
                       (consent-vcs--option-value
                        options "include-ignored?"))
                  '("--ignored=matching"))))
              (result (apply #'consent-vcs--run-git root arguments)))
         (if (equal (plist-get result :exit) 0)
             (consent-vcs--parse-status-output
              root (plist-get result :output))
           (consent-vcs--empty-status
            'git
            (consent-vcs-outcome
             'permission-denied
             (string-trim (plist-get result :output)))))))
      ('unsupported-vcs
       (consent-vcs--empty-status
        'unsupported
        (plist-get info :outcome)))
      ('git-not-found
       (consent-vcs--empty-status 'git (plist-get info :outcome)))
      (_
       (consent-vcs--empty-status 'none (plist-get info :outcome))))))

(defun consent-vcs-branch-datum (&optional options)
  "Return the current branch datum or a VCS outcome outside repositories."
  (let ((status (consent-vcs-status-datum options)))
    (if (consent-vcs--record-p status "vcs-status")
        (let ((outcome (consent-vcs-field-value status "outcome")))
          (if (equal (consent--symbol-name
                      (consent-vcs-field-value outcome "status"))
                     "ok")
              (consent-vcs-field-value status "branch")
            outcome))
      status)))

(defun consent-vcs--raw-status-kind (status-token)
  "Return normalized raw diff status from STATUS-TOKEN."
  (if (> (length status-token) 0)
      (consent-vcs--status-char-name (aref status-token 0))
    "unknown"))

(defun consent-vcs--raw-status-score (status-token)
  "Return raw diff score suffix from STATUS-TOKEN, or nil."
  (when (> (length status-token) 1)
    (string-to-number (substring status-token 1))))

(defun consent-vcs--parse-raw-diff-record (metadata rest)
  "Parse raw diff METADATA and following path tokens REST."
  (let* ((fields (consent-vcs--split-spaces metadata))
         (old-mode-token (consent-vcs--list-ref fields 0 ":000000"))
         (new-mode (consent-vcs--list-ref fields 1 "000000"))
         (old-object (consent-vcs--list-ref fields 2 "0000000"))
         (new-object (consent-vcs--list-ref fields 3 "0000000"))
         (status-token (consent-vcs--list-ref fields 4 "X"))
         (old-mode (if (string-prefix-p ":" old-mode-token)
                       (substring old-mode-token 1)
                     old-mode-token))
         (status (consent-vcs--raw-status-kind status-token))
         (score (consent-vcs--raw-status-score status-token)))
    (if (member status '("renamed" "copied"))
        (cons
         (consent-vcs-diff-file
          status
          (consent-vcs--list-ref rest 1 "")
          (consent-vcs--list-ref rest 0 "")
          old-mode
          new-mode
          old-object
          new-object
          score)
         (nthcdr (min 2 (length rest)) rest))
      (cons
       (consent-vcs-diff-file
        status
        (consent-vcs--list-ref rest 0 "")
        nil
        old-mode
        new-mode
        old-object
        new-object
        score)
       (nthcdr (min 1 (length rest)) rest)))))

(defun consent-vcs--parse-raw-diff (text)
  "Parse Git raw diff -z TEXT into diff file records."
  (let ((tokens (consent-vcs--split-nul text))
        files)
    (while tokens
      (let ((token (pop tokens)))
        (when (string-prefix-p ":" token)
          (let ((parsed (consent-vcs--parse-raw-diff-record token tokens)))
            (push (car parsed) files)
            (setq tokens (cdr parsed))))))
    (nreverse files)))

(defun consent-vcs-diff-datum (&optional options)
  "Return current Git raw diff summary as a VCS diff datum."
  (let ((info (consent-vcs--root-info options)))
    (if (eq (plist-get info :status) 'ok)
        (let* ((root (plist-get info :root))
               (arguments
                (append
                 '("diff" "--raw" "-z")
                 (when (or (consent-vcs--scheme-true-p
                            (consent-vcs--option-value
                             options "cached?"))
                           (consent-vcs--scheme-true-p
                            (consent-vcs--option-value
                             options "staged?")))
                   '("--cached"))))
               (result (apply #'consent-vcs--run-git root arguments)))
          (consent-vcs-diff-summary
           'git
           (if (equal (plist-get result :exit) 0)
               (consent-vcs--parse-raw-diff (plist-get result :output))
             nil)))
      (consent-vcs-diff-summary
       (if (eq (plist-get info :status) 'unsupported-vcs)
           'unsupported
         'none)
       nil))))

(defun consent-vcs--split-log-record (record)
  "Split one formatted Git log RECORD into fields."
  (split-string record "\x1f"))

(defun consent-vcs--parse-commit-record (record)
  "Parse one formatted Git log RECORD."
  (let* ((fields (consent-vcs--split-log-record record))
         (oid (consent-vcs--list-ref fields 0 ""))
         (parents-text (consent-vcs--list-ref fields 1 ""))
         (subject (consent-vcs--list-ref fields 2 ""))
         (author (consent-vcs--list-ref fields 3 ""))
         (timestamp (consent-vcs--list-ref fields 4 "")))
    (consent-vcs-commit-summary
     oid
     (if (string-empty-p parents-text)
         nil
       (split-string parents-text " " t))
     subject
     author
     timestamp)))

(defun consent-vcs-recent-commits-datum (count &optional options)
  "Return up to COUNT recent commit summary datums."
  (let ((info (consent-vcs--root-info options)))
    (if (eq (plist-get info :status) 'ok)
        (let* ((root (plist-get info :root))
               (limit (max 0 count))
               (result
                (consent-vcs--run-git
                 root
                 "log"
                 "-n" (number-to-string limit)
                 "--pretty=format:%H%x1f%P%x1f%s%x1f%an <%ae>%x1f%cI%x1e")))
          (if (equal (plist-get result :exit) 0)
              (mapcar #'consent-vcs--parse-commit-record
                      (split-string (plist-get result :output) "\x1e" t))
            nil))
      nil)))

(defun consent-vcs--safe-relative-path (root path)
  "Return PATH when it safely names a file under ROOT."
  (when (or (string-empty-p path)
            (file-name-absolute-p path)
            (file-remote-p path))
    (consent--eval-error
     "VCS path must be a local repository-relative path: %s" path))
  (let ((expanded (expand-file-name path root)))
    (unless (file-in-directory-p expanded root)
      (consent--eval-error
       "VCS path escapes repository root: %s" path))
    path))

(defun consent-vcs--mutation-paths (root options)
  "Return validated repository-relative mutation paths from OPTIONS."
  (let ((paths (consent-vcs--option-string-list options "paths")))
    (unless paths
      (consent--eval-error "VCS mutation requires at least one path"))
    (mapcar
     (lambda (path)
       (consent-vcs--safe-relative-path root path))
     paths)))

(defun consent-vcs--unsafe-remote-name-p (remote)
  "Return non-nil when REMOTE looks like a URL, credential, or invalid name."
  (or (string-empty-p remote)
      (string-match-p "://" remote)
      (string-match-p "@" remote)
      (string-match-p "[[:space:]]" remote)))

(defun consent-vcs--unsafe-ref-name-p (name)
  "Return non-nil when NAME is unsafe for a branch/ref argument."
  (or (string-empty-p name)
      (string-prefix-p "-" name)
      (string-match-p "[[:space:]]" name)
      (string-match-p "\\.\\." name)
      (string-match-p "[~^:?*\\[]" name)
      (string-match-p "\\\\" name)
      (string-match-p "@{" name)
      (string-match-p "//" name)
      (string-suffix-p "/" name)
      (string-suffix-p ".lock" name)))

(defun consent-vcs--required-string-option (options name operation)
  "Return required string option NAME for OPERATION."
  (let ((value (consent-vcs--option-string options name)))
    (unless (and value (not (string-empty-p (string-trim value))))
      (consent--eval-error
       "VCS %s requires non-empty %s option"
       operation
       name))
    value))

(defun consent-vcs--mutation-grants (options)
  "Return VCS grants from OPTIONS."
  (consent-vcs--option-datum-list options "grants"))

(defun consent-vcs--mutation-approvals (options)
  "Return VCS approvals from OPTIONS."
  (consent-vcs--option-datum-list options "approvals"))

(defun consent-vcs--outcome-result-status (outcome)
  "Return result status for OUTCOME."
  (let ((status (consent-vcs--name
                 (consent-vcs-field-value outcome "status"))))
    (cond
     ((equal status "ok") 'ok)
     ((equal status "denied") 'denied)
     (t 'error))))

(defun consent-vcs--git-failure-outcome
    (output &optional remote-operation)
  "Return a VCS outcome for failed Git OUTPUT."
  (let ((text (string-trim (or output "")))
        (case-fold-search t))
    (cond
     ((and remote-operation
           (string-match-p
            "\\(authentication\\|permission denied\\|could not read\
 username\\)"
            text))
      (consent-vcs-outcome
       'remote-authentication-failed
       (if (string-empty-p text)
           "Remote authentication failed."
         text)))
     (remote-operation
      (consent-vcs-outcome
       'remote-unavailable
       (if (string-empty-p text)
           "Remote is unavailable."
         text)))
     ((string-match-p "\\(conflict\\|unmerged\\)" text)
      (consent-vcs-outcome
       'conflict
       (if (string-empty-p text)
           "Repository has conflicts."
         text)))
     ((string-match-p "\\(dirty\\|local changes\\)" text)
      (consent-vcs-outcome
       'dirty-index
       (if (string-empty-p text)
           "Repository index is dirty."
         text)))
     (t
      (consent-vcs-outcome
       'permission-denied
       (if (string-empty-p text)
           "Git operation failed."
         text))))))

(defun consent-vcs--record-capability-audit
    (request decision result)
  "Audit REQUEST, DECISION, and RESULT as a VCS capability event."
  (let* ((audit
          (consent-vcs-capability-audit request decision result))
         (operation (consent-vcs-field-value request "operation"))
         (operation-name (consent-vcs--name operation))
         (decision-name (consent-vcs-capability-decision-status
                         decision))
         (result-name
          (consent-vcs--name
           (consent-vcs-field-value result "status")))
         (outcome-name (consent-vcs--result-outcome-status result))
         (remote-name
          (or (consent-vcs--request-argument request "remote")
              consent-false)))
    (consent-audit-record
     'vcs-capability-audit
     `((adapter . emacs-vcs)
       (audit . ,audit)
       (operation . ,(intern operation-name))
       (authority . ,(intern (consent-vcs--operation-authority
                              operation-name)))
       (remote? . ,(if (consent-vcs--remote-operation-p operation-name)
                       t
                     nil))
       (remote . ,remote-name)
       (decision . ,(intern decision-name))
       (result . ,(intern result-name))
       (outcome . ,(and outcome-name (intern outcome-name)))))))

(defun consent-vcs--mutation-request
    (operation authority root arguments)
  "Return a VCS mutation request for OPERATION and ARGUMENTS."
  (consent-vcs-capability-request
   (consent-vcs--request-id)
   operation
   authority
   (cons
    (consent-vcs--field
     "repository"
     (and root (directory-file-name (file-truename root))))
    arguments)))

(defun consent-vcs--finish-mutation
    (request decision outcome)
  "Build and audit a VCS mutation result for REQUEST and DECISION."
  (let ((result
         (consent-vcs-capability-result
          (consent-vcs-field-value request "id")
          (consent-vcs--outcome-result-status outcome)
          outcome)))
    (consent-vcs--record-capability-audit request decision result)
    result))

(defun consent-vcs--run-authorized-mutation
    (request options performer)
  "Authorize REQUEST using OPTIONS, then call PERFORMER when allowed."
  (let* ((decision
          (consent-vcs-authorize-capability-request
           request
           (consent-vcs--mutation-grants options)
           (consent-vcs--mutation-approvals options)))
         (decision-status
          (consent-vcs-capability-decision-status decision)))
    (if (equal decision-status "approved")
        (funcall performer decision)
      (consent-vcs--finish-mutation
       request
       decision
       (consent-vcs-outcome
        'denied
        (consent-vcs-field-value decision "reason"))))))

(defun consent-vcs--repository-mutation-result
    (operation options request-arguments git-arguments success-message)
  "Return result for repository mutating OPERATION using GIT-ARGUMENTS."
  (let ((info (consent-vcs--root-info options)))
    (pcase (plist-get info :status)
      ('ok
       (let* ((root (plist-get info :root))
              (request
               (consent-vcs--mutation-request
                operation
                "repository-mutation"
                root
                request-arguments)))
         (consent-vcs--run-authorized-mutation
          request
          options
          (lambda (decision)
            (let* ((result
                    (apply #'consent-vcs--run-git
                           root
                           git-arguments))
                   (outcome
                    (if (equal (plist-get result :exit) 0)
                        (consent-vcs-outcome 'ok success-message)
                      (consent-vcs--git-failure-outcome
                       (plist-get result :output)))))
              (consent-vcs--finish-mutation
               request decision outcome))))))
      ('unsupported-vcs
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome)))
      ('git-not-found
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome)))
      (_
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome))))))

(defun consent-vcs--remote-mutation-result
    (operation options git-arguments success-message)
  "Return result for remote mutating OPERATION using GIT-ARGUMENTS."
  (let ((info (consent-vcs--root-info options)))
    (pcase (plist-get info :status)
      ('ok
       (let* ((root (plist-get info :root))
              (raw-remote
               (or (consent-vcs--option-string options "remote")
                   "origin"))
              (unsafe-remote
               (consent-vcs--unsafe-remote-name-p raw-remote))
              (remote
               (if unsafe-remote "[redacted]" raw-remote))
              (request
               (consent-vcs--mutation-request
                operation
                "remote-mutation"
                root
                (list (consent-vcs--field "remote" remote)))))
         (consent-vcs--run-authorized-mutation
          request
          options
          (lambda (decision)
            (let ((outcome
                   (cond
                    (unsafe-remote
                     (consent-vcs-outcome
                      'permission-denied
                      "VCS remote must be a remote name, not a URL."))
                    ((consent-vcs--scheme-true-p
                      (consent-vcs--option-value
                       options "live-remote?"))
                     (let ((result
                            (apply #'consent-vcs--run-git
                                   root
                                   (append git-arguments (list remote)))))
                       (if (equal (plist-get result :exit) 0)
                           (consent-vcs-outcome
                            'ok
                            success-message)
                         (consent-vcs--git-failure-outcome
                          (plist-get result :output)
                          t))))
                    (t
                     (consent-vcs-outcome
                      'remote-unavailable
                      "Live remote VCS operations require explicit\
 live-remote? authority.")))))
              (consent-vcs--finish-mutation
               request decision outcome))))))
      ('unsupported-vcs
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome)))
      ('git-not-found
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome)))
      (_
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome))))))

(defun consent-vcs--local-mutation-result
    (operation options git-arguments success-message)
  "Return result for local mutating OPERATION using GIT-ARGUMENTS."
  (let ((info (consent-vcs--root-info options)))
    (pcase (plist-get info :status)
      ('ok
       (let* ((root (plist-get info :root))
              (paths (consent-vcs--mutation-paths root options))
              (request
               (consent-vcs--mutation-request
                operation
                "repository-mutation"
                root
                (list
                 (consent-vcs--field "paths" paths)))))
         (consent-vcs--run-authorized-mutation
          request
          options
          (lambda (decision)
            (let* ((result
                    (apply #'consent-vcs--run-git
                           root
                           (append git-arguments
                                   '("--")
                                   paths)))
                   (outcome
                    (if (equal (plist-get result :exit) 0)
                        (consent-vcs-outcome 'ok success-message)
                      (consent-vcs--git-failure-outcome
                       (plist-get result :output)))))
              (consent-vcs--finish-mutation
               request decision outcome))))))
      ('unsupported-vcs
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome)))
      ('git-not-found
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome)))
      (_
       (consent-vcs-capability-result
        (consent-vcs--request-id)
        'error
        (plist-get info :outcome))))))

(defun consent-vcs-stage-datum (&optional options)
  "Authorize and stage selected paths, returning a VCS result datum."
  (consent-vcs--local-mutation-result
   "stage"
   options
   '("add")
   "Staged selected paths."))

(defun consent-vcs-unstage-datum (&optional options)
  "Authorize and unstage selected paths, returning a VCS result datum."
  (consent-vcs--local-mutation-result
   "unstage"
   options
   '("reset" "-q" "HEAD")
   "Unstaged selected paths."))

(defun consent-vcs-commit-datum (&optional options)
  "Authorize and commit staged changes, returning a VCS result datum."
  (let ((message
         (consent-vcs--required-string-option
          options
          "message"
          "commit")))
    (consent-vcs--repository-mutation-result
     "commit"
     options
     (list (consent-vcs--field "message" message))
     (list "commit" "-q" "-m" message)
     "Committed staged changes.")))

(defun consent-vcs-branch-create-datum (&optional options)
  "Authorize and create a branch, returning a VCS result datum."
  (let ((branch
         (consent-vcs--required-string-option
          options
          "name"
          "branch-create")))
    (when (consent-vcs--unsafe-ref-name-p branch)
      (consent--eval-error
       "VCS branch name is not safe: %s"
       branch))
    (consent-vcs--repository-mutation-result
     "branch-create"
     options
     (list (consent-vcs--field "branch" branch))
     (list "branch" "--" branch)
     "Created branch.")))

(defun consent-vcs-switch-datum (&optional options)
  "Authorize and switch branches, returning a VCS result datum."
  (let ((branch
         (consent-vcs--required-string-option
          options
          "branch"
          "switch")))
    (when (consent-vcs--unsafe-ref-name-p branch)
      (consent--eval-error
       "VCS branch name is not safe: %s"
       branch))
    (consent-vcs--repository-mutation-result
     "switch"
     options
     (list (consent-vcs--field "branch" branch))
     (list "switch" "--" branch)
     "Switched branch.")))

(defun consent-vcs-fetch-datum (&optional options)
  "Authorize a fetch intent without contacting a live remote by default."
  (consent-vcs--remote-mutation-result
   "fetch"
   options
   '("fetch")
   "Fetched from remote."))

(defun consent-vcs-pull-datum (&optional options)
  "Authorize a pull intent without contacting a live remote by default."
  (consent-vcs--remote-mutation-result
   "pull"
   options
   '("pull")
   "Pulled from remote."))

(defun consent-vcs-push-datum (&optional options)
  "Authorize a push intent without contacting a live remote by default."
  (consent-vcs--remote-mutation-result
   "push"
   options
   '("push")
   "Pushed to remote."))

(provide 'consent-vcs)

;;; consent-vcs.el ends here
