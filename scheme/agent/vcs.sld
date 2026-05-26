;;; vcs.sld --- Portable Agent Scheme VCS datum library
;;;
;;; This host-neutral library owns canonical VCS datums and pure parsers for
;;; stable Git machine formats. Host adapters obtain repository observations,
;;; but Scheme-visible values stay printable data.

(define-library (agent vcs)
  (export vcs-field
          vcs-field-value
          make-vcs-repository
          make-vcs-branch
          make-vcs-remote
          make-vcs-commit-summary
          make-vcs-status
          vcs-status?
          vcs-status-branch
          vcs-status-entries
          make-vcs-status-entry
          vcs-status-entry?
          vcs-status-entry-kind
          vcs-status-entry-path
          vcs-status-entry-index-status
          vcs-status-entry-worktree-status
          vcs-status-entry-conflict?
          make-vcs-operation-state
          make-vcs-conflict-state
          make-vcs-diff-summary
          make-vcs-diff-file
          vcs-diff-summary-files
          make-vcs-capability-request
          vcs-capability-request?
          vcs-capability-request-id
          vcs-capability-request-operation
          make-vcs-capability-result
          make-vcs-capability-grant
          make-vcs-approval-decision
          make-vcs-capability-decision
          vcs-capability-decision?
          vcs-capability-decision-status
          vcs-authorize-capability-request
          make-vcs-capability-audit
          vcs-capability-audit?
          make-vcs-outcome
          vcs-outcome-status
          vcs-known-outcome?
          vcs-read-only-operation?
          vcs-mutating-operation?
          vcs-remote-operation?
          vcs-operation-required-authority
          parse-git-status-porcelain-v2-z
          parse-git-raw-diff-z)
  (import (scheme base))
  (begin
    (define (vcs-field name . values)
      "Return a Scheme-readable record field named NAME with VALUES."
      #((parameters . ((name . "Symbol naming the VCS field.")
                       (values . "Zero or more Scheme-readable field values.")))
        (returns . "A field pair whose car is NAME and whose cdr is VALUES.")
        (effects . (pure)))
      (cons name values))

    (define (vcs-field-value record field default)
      "Return FIELD's first value from RECORD, or DEFAULT when absent."
      #((parameters . ((record . "VCS record represented as a tagged list.")
                       (field . "Symbol naming the field to read.")
                       (default . "Fallback value returned when FIELD is absent or empty.")))
        (returns . "The first stored value for FIELD, or DEFAULT.")
        (effects . (pure)))
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    (define (vcs-record? datum tag)
      "Report whether DATUM is a record tagged by TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (make-vcs-repository system root identity)
      "Return an explicit repository identity/root record."
      #((parameters . ((system . "VCS system symbol, such as git.")
                       (root . "Repository root path or handle metadata.")
                       (identity . "Stable repository identity metadata, or #f.")))
        (returns . "A `vcs-repository` datum.")
        (effects . (pure)))
      (list 'vcs-repository
            (vcs-field 'system system)
            (vcs-field 'root root)
            (vcs-field 'identity identity)))

    (define (make-vcs-branch head oid upstream ahead behind detached?)
      "Return a branch or detached-head record."
      #((parameters . ((head . "Branch name, or #f when detached.")
                       (oid . "Current object id, or #f when unavailable.")
                       (upstream . "Upstream branch name, or #f.")
                       (ahead . "Ahead count relative to upstream.")
                       (behind . "Behind count relative to upstream.")
                       (detached? . "#t when the worktree is detached from a branch.")))
        (returns . "A `vcs-branch` datum.")
        (effects . (pure)))
      (list 'vcs-branch
            (vcs-field 'head head)
            (vcs-field 'oid oid)
            (vcs-field 'upstream upstream)
            (vcs-field 'ahead ahead)
            (vcs-field 'behind behind)
            (vcs-field 'detached? detached?)))

    (define (make-vcs-remote name url-metadata)
      "Return safe remote metadata without requiring a raw host remote object."
      #((parameters . ((name . "Remote name.")
                       (url-metadata . "Safe, redacted, or classified URL metadata.")))
        (returns . "A `vcs-remote` datum.")
        (effects . (pure)))
      (list 'vcs-remote
            (vcs-field 'name name)
            (vcs-field 'url url-metadata)))

    (define (make-vcs-commit-summary oid parents subject author timestamp)
      "Return a compact commit summary record suitable for log adapters."
      #((parameters . ((oid . "Commit object id.")
                       (parents . "List of parent object ids.")
                       (subject . "Commit subject line.")
                       (author . "Author metadata safe for this context.")
                       (timestamp . "Commit timestamp datum.")))
        (returns . "A `vcs-commit-summary` datum.")
        (effects . (pure)))
      (list 'vcs-commit-summary
            (vcs-field 'oid oid)
            (vcs-field 'parents parents)
            (vcs-field 'subject subject)
            (vcs-field 'author author)
            (vcs-field 'timestamp timestamp)))

    (define (make-vcs-status system repository branch entries operation-state outcome)
      "Return a repository status snapshot from pure Scheme-readable fields."
      #((parameters . ((system . "VCS system symbol, such as git.")
                       (repository . "Repository record.")
                       (branch . "Branch record.")
                       (entries . "List of status entry records.")
                       (operation-state . "Operation-state record for merge, rebase, cherry-pick, or bisect context.")
                       (outcome . "Outcome datum describing adapter status.")))
        (returns . "A `vcs-status` snapshot datum.")
        (effects . (pure)))
      (list 'vcs-status
            (vcs-field 'system system)
            (vcs-field 'repository repository)
            (vcs-field 'branch branch)
            (vcs-field 'entries entries)
            (vcs-field 'operation-state operation-state)
            (vcs-field 'outcome outcome)))

    (define (vcs-status? datum)
      "Return #t when DATUM is a VCS status record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a VCS status record; otherwise #f.")
        (effects . (pure)))
      (and (pair? datum) (eq? (car datum) 'vcs-status)))

    (define (vcs-status-branch status)
      "Return STATUS's branch or detached-head record."
      #((parameters . ((status . "VCS status datum.")))
        (returns . "The branch record, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value status 'branch #f))

    (define (vcs-status-entries status)
      "Return STATUS's status entry list."
      #((parameters . ((status . "VCS status datum.")))
        (returns . "The status entry list, or the empty list.")
        (effects . (pure)))
      (vcs-field-value status 'entries '()))

    (define (make-vcs-status-entry kind path index-status worktree-status details)
      "Return a worktree/index status entry with additional DETAILS fields."
      #((parameters . ((kind . "Normalized entry kind symbol.")
                       (path . "Repository-relative path.")
                       (index-status . "Index-side status symbol.")
                       (worktree-status . "Worktree-side status symbol.")
                       (details . "Additional VCS fields for backend-specific metadata.")))
        (returns . "A `vcs-status-entry` datum.")
        (effects . (pure)))
      (append
       (list 'vcs-status-entry
             (vcs-field 'kind kind)
             (vcs-field 'path path)
             (vcs-field 'index-status index-status)
             (vcs-field 'worktree-status worktree-status))
       details))

    (define (vcs-status-entry? datum)
      "Return #t when DATUM is a VCS status entry record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a VCS status entry; otherwise #f.")
        (effects . (pure)))
      (and (pair? datum) (eq? (car datum) 'vcs-status-entry)))

    (define (vcs-status-entry-kind entry)
      "Return ENTRY's normalized kind."
      #((parameters . ((entry . "VCS status entry datum.")))
        (returns . "The normalized entry kind, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value entry 'kind #f))

    (define (vcs-status-entry-path entry)
      "Return ENTRY's repository-relative path."
      #((parameters . ((entry . "VCS status entry datum.")))
        (returns . "The repository-relative path, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value entry 'path #f))

    (define (vcs-status-entry-index-status entry)
      "Return ENTRY's index-side status."
      #((parameters . ((entry . "VCS status entry datum.")))
        (returns . "The index-side status symbol, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value entry 'index-status #f))

    (define (vcs-status-entry-worktree-status entry)
      "Return ENTRY's worktree-side status."
      #((parameters . ((entry . "VCS status entry datum.")))
        (returns . "The worktree-side status symbol, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value entry 'worktree-status #f))

    (define (vcs-status-entry-conflict? entry)
      "Return #t when ENTRY represents an unresolved conflict."
      #((parameters . ((entry . "VCS status entry datum.")))
        (returns . "#t when ENTRY is marked as conflicted; otherwise #f.")
        (effects . (pure)))
      (eq? (vcs-field-value entry 'kind #f) 'conflicted))

    (define (make-vcs-operation-state merge rebase cherry-pick bisect)
      "Return merge/rebase/cherry-pick/bisect state as explicit data."
      #((parameters . ((merge . "Merge state metadata, or #f.")
                       (rebase . "Rebase state metadata, or #f.")
                       (cherry-pick . "Cherry-pick state metadata, or #f.")
                       (bisect . "Bisect state metadata, or #f.")))
        (returns . "A `vcs-operation-state` datum.")
        (effects . (pure)))
      (list 'vcs-operation-state
            (vcs-field 'merge merge)
            (vcs-field 'rebase rebase)
            (vcs-field 'cherry-pick cherry-pick)
            (vcs-field 'bisect bisect)))

    (define (make-vcs-conflict-state type paths)
      "Return conflict state independent of any host-native merge object."
      #((parameters . ((type . "Conflict type symbol.")
                       (paths . "Repository-relative paths participating in the conflict.")))
        (returns . "A `vcs-conflict-state` datum.")
        (effects . (pure)))
      (list 'vcs-conflict-state
            (vcs-field 'type type)
            (vcs-field 'paths paths)))

    (define (make-vcs-diff-summary system files)
      "Return a diff summary whose files may compose with `(agent diff)' hunks."
      #((parameters . ((system . "VCS system symbol, such as git.")
                       (files . "List of file-level diff summary records.")))
        (returns . "A `vcs-diff-summary` datum.")
        (effects . (pure)))
      (list 'vcs-diff-summary
            (vcs-field 'system system)
            (vcs-field 'files files)))

    (define (make-vcs-diff-file status path orig-path old-mode new-mode old-object new-object score)
      "Return one file-level raw diff summary."
      #((parameters . ((status . "Normalized file diff status symbol.")
                       (path . "Current repository-relative path.")
                       (orig-path . "Original path for renames/copies, or #f.")
                       (old-mode . "Old file mode token.")
                       (new-mode . "New file mode token.")
                       (old-object . "Old object id token.")
                       (new-object . "New object id token.")
                       (score . "Rename/copy score, or #f.")))
        (returns . "A `vcs-diff-file` datum.")
        (effects . (pure)))
      (list 'vcs-diff-file
            (vcs-field 'status status)
            (vcs-field 'path path)
            (vcs-field 'orig-path orig-path)
            (vcs-field 'old-mode old-mode)
            (vcs-field 'new-mode new-mode)
            (vcs-field 'old-object old-object)
            (vcs-field 'new-object new-object)
            (vcs-field 'score score)))

    (define (vcs-diff-summary-files diff)
      "Return DIFF's file summary list."
      #((parameters . ((diff . "VCS diff summary datum.")))
        (returns . "The file summary list, or the empty list.")
        (effects . (pure)))
      (vcs-field-value diff 'files '()))

    (define (make-vcs-capability-request id operation authority arguments)
      "Return a host-adapter request datum for a VCS operation."
      #((parameters . ((id . "Stable request id.")
                       (operation . "VCS operation symbol.")
                       (authority . "Requested authority family.")
                       (arguments . "Operation arguments as Scheme-readable data.")))
        (returns . "A `vcs-capability-request` datum with derived authority metadata.")
        (effects . (pure))
        (see-also . (vcs-authorize-capability-request vcs-operation-required-authority)))
      (list 'vcs-capability-request
            (vcs-field 'id id)
            (vcs-field 'operation operation)
            (vcs-field 'authority authority)
            (vcs-field 'arguments arguments)
            (vcs-field 'required-authority
                       (vcs-operation-required-authority operation))
            (vcs-field 'remote? (vcs-remote-operation? operation))
            (vcs-field 'mutating? (vcs-mutating-operation? operation))))

    (define (vcs-capability-request? datum)
      "Return #t when DATUM is a VCS capability request record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a VCS capability request; otherwise #f.")
        (effects . (pure)))
      (vcs-record? datum 'vcs-capability-request))

    (define (vcs-capability-request-id request)
      "Return REQUEST's stable identifier."
      #((parameters . ((request . "VCS capability request datum.")))
        (returns . "The request id, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value request 'id #f))

    (define (vcs-capability-request-operation request)
      "Return REQUEST's operation symbol."
      #((parameters . ((request . "VCS capability request datum.")))
        (returns . "The operation symbol, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value request 'operation #f))

    (define (make-vcs-capability-result id status value)
      "Return a host-adapter result datum for a VCS operation."
      #((parameters . ((id . "Request id associated with the result.")
                       (status . "Result status symbol.")
                       (value . "Result payload, often a VCS record or outcome datum.")))
        (returns . "A `vcs-capability-result` datum.")
        (effects . (pure)))
      (list 'vcs-capability-result
            (vcs-field 'id id)
            (vcs-field 'status status)
            (vcs-field 'value value)))

    (define (make-vcs-capability-grant id authority operations repository remote)
      "Return a scoped VCS authority grant record."
      #((parameters . ((id . "Stable grant id.")
                       (authority . "Authority family granted, or all.")
                       (operations . "Allowed operation symbol, `all`, or list of operation symbols.")
                       (repository . "Repository scope value, or #f/all for unrestricted.")
                       (remote . "Remote scope value, or #f/all for unrestricted.")))
        (returns . "A `vcs-capability-grant` datum.")
        (effects . (pure)))
      (list 'vcs-capability-grant
            (vcs-field 'id id)
            (vcs-field 'authority authority)
            (vcs-field 'operations operations)
            (vcs-field 'repository repository)
            (vcs-field 'remote remote)))

    (define (make-vcs-approval-decision id request-id status reason)
      "Return an explicit approval decision for one VCS request."
      #((parameters . ((id . "Stable approval decision id.")
                       (request-id . "Id of the request this decision answers.")
                       (status . "Approval status symbol, usually approved or denied.")
                       (reason . "Human-readable explanation for the decision.")))
        (returns . "A `vcs-approval-decision` datum.")
        (effects . (pure)))
      (list 'vcs-approval-decision
            (vcs-field 'id id)
            (vcs-field 'request-id request-id)
            (vcs-field 'status status)
            (vcs-field 'reason reason)))

    (define (make-vcs-capability-decision request status grant approval reason)
      "Return a VCS capability authorization decision record."
      #((parameters . ((request . "VCS capability request datum.")
                       (status . "Decision status symbol, usually approved or denied.")
                       (grant . "Grant datum that authorized the request, or #f.")
                       (approval . "Approval decision datum that authorized the request, or #f.")
                       (reason . "Human-readable policy explanation.")))
        (returns . "A `vcs-capability-decision` datum summarizing the authorization result.")
        (effects . (pure)))
      (let ((operation (vcs-capability-request-operation request)))
        (let ((required-authority (vcs-operation-required-authority operation)))
          (list 'vcs-capability-decision
                (vcs-field 'id (vcs-capability-request-id request))
                (vcs-field 'operation operation)
                (vcs-field 'authority required-authority)
                (vcs-field 'requested-authority
                           (vcs-field-value request 'authority #f))
                (vcs-field 'status status)
                (vcs-field 'grant
                           (if grant (vcs-field-value grant 'id #f) #f))
                (vcs-field 'approval
                           (if approval
                               (vcs-field-value approval 'id #f)
                               #f))
                (vcs-field 'reason reason)
                (vcs-field 'remote? (vcs-remote-operation? operation))))))

    (define (vcs-capability-decision? datum)
      "Return #t when DATUM is a VCS capability decision record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a VCS capability decision; otherwise #f.")
        (effects . (pure)))
      (vcs-record? datum 'vcs-capability-decision))

    (define (vcs-capability-decision-status decision)
      "Return DECISION's status symbol."
      #((parameters . ((decision . "VCS capability decision datum.")))
        (returns . "The decision status symbol, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value decision 'status #f))

    (define (make-vcs-outcome status message)
      "Return an explicit VCS outcome instead of a generic error."
      #((parameters . ((status . "Outcome status symbol.")
                       (message . "Human-readable outcome message.")))
        (returns . "A `vcs-outcome` datum.")
        (effects . (pure)))
      (list 'vcs-outcome
            (vcs-field 'status status)
            (vcs-field 'message message)))

    (define (vcs-outcome-status outcome)
      "Return OUTCOME's status symbol."
      #((parameters . ((outcome . "VCS outcome datum.")))
        (returns . "The outcome status symbol, or #f when absent.")
        (effects . (pure)))
      (vcs-field-value outcome 'status #f))

    (define (vcs-outcome? datum)
      "Report whether DATUM is a VCS outcome record."
      (vcs-record? datum 'vcs-outcome))

    ;; Read-only VCS observations never mutate repository state.
    (define vcs-read-only-operations
      '(status refs branches commit-summary diff-summary remotes operation-state))

    ;; Mutating VCS operations require a separate policy-gated capability family.
    (define vcs-mutating-operations
      '(stage unstage commit branch-create branch-delete checkout switch
        fetch pull push merge rebase cherry-pick revert reset))

    ;; Remote VCS operations may communicate with and mutate remote state.
    (define vcs-remote-operations
      '(fetch pull push))

    ;; Stable VCS outcome vocabulary shared by adapters.
    (define vcs-known-outcomes
      '(ok no-vcs unsupported-vcs git-not-found dirty-index conflict timeout
        permission-denied remote-authentication-failed remote-unavailable
        denied cancelled))

    (define (vcs-read-only-operation? operation)
      "Return #t when OPERATION is a read-only VCS observation."
      #((parameters . ((operation . "VCS operation symbol to classify.")))
        (returns . "#t when OPERATION is read-only; otherwise #f.")
        (effects . (pure)))
      (if (memq operation vcs-read-only-operations) #t #f))

    (define (vcs-mutating-operation? operation)
      "Return #t when OPERATION mutates repository state."
      #((parameters . ((operation . "VCS operation symbol to classify.")))
        (returns . "#t when OPERATION mutates repository state; otherwise #f.")
        (effects . (pure)))
      (if (memq operation vcs-mutating-operations) #t #f))

    (define (vcs-remote-operation? operation)
      "Return #t when OPERATION communicates with a remote VCS endpoint."
      #((parameters . ((operation . "VCS operation symbol to classify.")))
        (returns . "#t when OPERATION may communicate with a remote endpoint; otherwise #f.")
        (effects . (pure)))
      (if (memq operation vcs-remote-operations) #t #f))

    (define (vcs-operation-required-authority operation)
      "Return OPERATION's required policy authority family."
      #((parameters . ((operation . "VCS operation symbol to classify.")))
        (returns . "Authority family symbol: read-only-observation, repository-mutation, remote-mutation, or unknown.")
        (effects . (pure)))
      (cond
       ((vcs-read-only-operation? operation) 'read-only-observation)
       ((vcs-remote-operation? operation) 'remote-mutation)
       ((vcs-mutating-operation? operation) 'repository-mutation)
       (else 'unknown)))

    (define (vcs-known-outcome? status)
      "Return #t when STATUS is part of the shared outcome vocabulary."
      #((parameters . ((status . "Outcome status symbol to check.")))
        (returns . "#t when STATUS is a known VCS outcome; otherwise #f.")
        (effects . (pure)))
      (if (memq status vcs-known-outcomes) #t #f))

    (define (vcs-request-argument request name default)
      "Return REQUEST's argument named NAME, or DEFAULT when absent."
      (let ((arguments (vcs-field-value request 'arguments '())))
        (let loop ((rest arguments))
          (cond
           ((null? rest) default)
           ((and (pair? (car rest)) (eq? (car (car rest)) name))
            (let ((values (cdr (car rest))))
              (if (null? values) default (car values))))
           (else
            (loop (cdr rest)))))))

    (define (vcs-operation-covered? operation operations)
      "Report whether OPERATIONS covers OPERATION."
      (cond
       ((eq? operations 'all) #t)
       ((pair? operations)
        (if (or (memq operation operations) (memq 'all operations)) #t #f))
       (else
        (eq? operation operations))))

    (define (vcs-scope-matches? scope value)
      "Report whether VALUE matches SCOPE, where #f and all mean unrestricted."
      (or (not scope) (eq? scope 'all) (equal? scope value)))

    (define (vcs-grant-allows? request grant)
      "Report whether GRANT authorizes REQUEST."
      (let ((operation (vcs-capability-request-operation request)))
        (let ((required-authority (vcs-operation-required-authority operation))
              (grant-authority (vcs-field-value grant 'authority #f)))
          (and (or (eq? grant-authority required-authority)
                   (eq? grant-authority 'all))
               (vcs-operation-covered?
                operation
                (vcs-field-value grant 'operations '()))
               (vcs-scope-matches?
                (vcs-field-value grant 'repository #f)
                (vcs-request-argument request 'repository #f))
               (vcs-scope-matches?
                (vcs-field-value grant 'remote #f)
                (vcs-request-argument request 'remote #f))))))

    (define (vcs-find-grant request grants)
      "Return the first GRANTS entry that authorizes REQUEST."
      (let loop ((rest grants))
        (cond
         ((null? rest) #f)
         ((vcs-grant-allows? request (car rest)) (car rest))
         (else (loop (cdr rest))))))

    (define (vcs-approval-allows? request approval)
      "Report whether APPROVAL authorizes REQUEST."
      (and (vcs-record? approval 'vcs-approval-decision)
           (equal? (vcs-capability-request-id request)
                   (vcs-field-value approval 'request-id #f))
           (eq? (vcs-field-value approval 'status #f) 'approved)))

    (define (vcs-find-approval request approvals)
      "Return the first APPROVALS entry that authorizes REQUEST."
      (let loop ((rest approvals))
        (cond
         ((null? rest) #f)
         ((vcs-approval-allows? request (car rest)) (car rest))
         (else (loop (cdr rest))))))

    (define (vcs-authorize-capability-request request grants approvals)
      "Return a fail-closed authorization decision for REQUEST."
      #((parameters . ((request . "VCS capability request datum to authorize.")
                       (grants . "Active VCS grant datums to check first.")
                       (approvals . "Explicit approval decision datums to check when grants do not authorize the request.")))
        (returns . "A VCS capability decision approving or denying REQUEST with an explanatory reason.")
        (effects . (pure))
        (see-also . (make-vcs-capability-request make-vcs-capability-grant make-vcs-approval-decision)))
      (let ((operation (vcs-capability-request-operation request)))
        (let ((required-authority (vcs-operation-required-authority operation))
              (requested-authority (vcs-field-value request 'authority #f)))
          (cond
           ((vcs-read-only-operation? operation)
            (make-vcs-capability-decision
             request 'approved #f #f "read-only observation"))
           ((not (vcs-mutating-operation? operation))
            (make-vcs-capability-decision
             request 'denied #f #f "unknown VCS operation"))
           ((not (eq? requested-authority required-authority))
            (make-vcs-capability-decision
             request
             'denied
             #f
             #f
             "requested VCS authority does not match operation"))
           (else
            (let ((grant (vcs-find-grant request grants)))
              (if grant
                  (make-vcs-capability-decision
                   request 'approved grant #f "authorized by VCS grant")
                  (let ((approval (vcs-find-approval request approvals)))
                    (if approval
                        (make-vcs-capability-decision
                         request
                         'approved
                         #f
                         approval
                         "authorized by VCS approval")
                        (make-vcs-capability-decision
                         request
                         'denied
                         #f
                         #f
                         "missing VCS mutation grant or approval"))))))))))

    (define (vcs-result-outcome-status result)
      "Return RESULT's VCS outcome status when it carries a VCS outcome."
      (let ((value (vcs-field-value result 'value #f)))
        (if (vcs-outcome? value)
            (vcs-outcome-status value)
            #f)))

    (define (make-vcs-capability-audit request decision result)
      "Return a stable audit event for a VCS authorization and result."
      #((parameters . ((request . "VCS capability request datum.")
                       (decision . "VCS capability decision datum.")
                       (result . "VCS capability result datum.")))
        (returns . "A `vcs-capability-audit` datum suitable for logs and transcripts.")
        (effects . (pure)))
      (let ((operation (vcs-capability-request-operation request)))
        (list 'vcs-capability-audit
              (vcs-field 'event 'vcs-capability-audit)
              (vcs-field 'id (vcs-capability-request-id request))
              (vcs-field 'operation operation)
              (vcs-field 'authority
                         (vcs-operation-required-authority operation))
              (vcs-field 'remote? (vcs-remote-operation? operation))
              (vcs-field 'decision
                         (vcs-capability-decision-status decision))
              (vcs-field 'result (vcs-field-value result 'status #f))
              (vcs-field 'outcome (vcs-result-outcome-status result)))))

    (define (vcs-capability-audit? datum)
      "Return #t when DATUM is a VCS capability audit record."
      #((parameters . ((datum . "Value to inspect.")))
        (returns . "#t when DATUM is tagged as a VCS capability audit record; otherwise #f.")
        (effects . (pure)))
      (vcs-record? datum 'vcs-capability-audit))

    (define (vcs-string-prefix? prefix text)
      "Return non-#f when TEXT starts with PREFIX."
      (let ((prefix-length (string-length prefix))
            (text-length (string-length text)))
        (and (<= prefix-length text-length)
             (let loop ((index 0))
               (cond
                ((= index prefix-length) #t)
                ((char=? (string-ref prefix index)
                         (string-ref text index))
                 (loop (+ index 1)))
                (else #f))))))

    (define (vcs-drop-prefix prefix text)
      "Return TEXT with PREFIX removed when present."
      (if (vcs-string-prefix? prefix text)
          (substring text (string-length prefix) (string-length text))
          text))

    (define (vcs-string-index text char start)
      "Return the first index of CHAR in TEXT at or after START, or #f."
      (let ((length (string-length text)))
        (let loop ((index start))
          (cond
           ((>= index length) #f)
           ((char=? (string-ref text index) char) index)
           (else (loop (+ index 1)))))))

    (define (vcs-split-on-char text char)
      "Split TEXT on CHAR, dropping empty fields used as final terminators."
      (let ((length (string-length text)))
        (let loop ((start 0) (index 0) (parts '()))
          (cond
           ((> index length)
            (reverse parts))
           ((= index length)
            (let ((part (substring text start index)))
              (reverse
               (if (= (string-length part) 0)
                   parts
                   (cons part parts)))))
           ((char=? (string-ref text index) char)
            (let ((part (substring text start index)))
              (loop (+ index 1)
                    (+ index 1)
                    (if (= (string-length part) 0)
                        parts
                        (cons part parts)))))
           (else
            (loop start (+ index 1) parts))))))

    (define (vcs-split-nul text)
      "Split a NUL-delimited Git machine-format string."
      (vcs-split-on-char text #\null))

    (define (vcs-split-spaces text)
      "Split TEXT into space-separated metadata fields."
      (vcs-split-on-char text #\space))

    (define (vcs-leading-fields text count)
      "Return the first COUNT fields and the remaining text after them."
      (let ((length (string-length text)))
        (let loop ((start 0) (remaining count) (fields '()))
          (if (= remaining 0)
              (cons (reverse fields) (substring text start length))
              (let ((separator (vcs-string-index text #\space start)))
                (if separator
                    (loop (+ separator 1)
                          (- remaining 1)
                          (cons (substring text start separator) fields))
                    (cons (reverse (cons (substring text start length) fields))
                          "")))))))

    (define (vcs-list-ref/default values index default)
      "Return LIST's INDEX value, or DEFAULT when INDEX is out of range."
      (let loop ((rest values) (cursor index))
        (cond
         ((null? rest) default)
         ((= cursor 0) (car rest))
         (else (loop (cdr rest) (- cursor 1))))))

    (define (vcs-parse-count text)
      "Convert a signed Git count field such as +2 or -1 to a nonnegative count."
      (let ((length (string-length text)))
        (let ((start
               (if (and (> length 0)
                        (or (char=? (string-ref text 0) #\+)
                            (char=? (string-ref text 0) #\-)))
                   1
                   0)))
          (let ((number (string->number (substring text start length))))
            (if number number 0)))))

    (define (vcs-status-char->symbol char)
      "Convert a one-character Git status code to an Agent Scheme symbol."
      (cond
       ((char=? char #\.) 'unchanged)
       ((char=? char #\space) 'unchanged)
       ((char=? char #\M) 'modified)
       ((char=? char #\A) 'added)
       ((char=? char #\D) 'deleted)
       ((char=? char #\T) 'type-changed)
       ((char=? char #\R) 'renamed)
       ((char=? char #\C) 'copied)
       ((char=? char #\U) 'unmerged)
       ((char=? char #\?) 'untracked)
       ((char=? char #\!) 'ignored)
       (else 'unknown)))

    (define (vcs-xy-index-status xy)
      "Convert a Git XY field to the index-side status."
      (if (> (string-length xy) 0)
          (vcs-status-char->symbol (string-ref xy 0))
          'unknown))

    (define (vcs-xy-worktree-status xy)
      "Convert a Git XY field to the worktree-side status."
      (if (> (string-length xy) 1)
          (vcs-status-char->symbol (string-ref xy 1))
          'unknown))

    (define (vcs-status-kind index-status worktree-status)
      "Return the status-entry kind implied by INDEX-STATUS and WORKTREE-STATUS."
      (cond
       ((not (eq? index-status 'unchanged)) index-status)
       ((not (eq? worktree-status 'unchanged)) worktree-status)
       (else 'unchanged)))

    (define (vcs-parse-submodule text)
      "Parse the four-character porcelain v2 submodule field."
      (let ((length (string-length text)))
        (list 'vcs-submodule
              (vcs-field 'state
                         (if (and (> length 0)
                                  (char=? (string-ref text 0) #\S))
                             'submodule
                             'none))
              (vcs-field 'commit-changed?
                         (and (> length 1)
                              (char=? (string-ref text 1) #\C)))
              (vcs-field 'tracked-changes?
                         (and (> length 2)
                              (char=? (string-ref text 2) #\M)))
              (vcs-field 'untracked?
                         (and (> length 3)
                              (char=? (string-ref text 3) #\U))))))

    (define (vcs-conflict-type xy)
      "Convert an unmerged XY field to a conflict type."
      (cond
       ((string=? xy "DD") 'both-deleted)
       ((string=? xy "AU") 'added-by-us)
       ((string=? xy "UD") 'deleted-by-them)
       ((string=? xy "UA") 'added-by-them)
       ((string=? xy "DU") 'deleted-by-us)
       ((string=? xy "AA") 'both-added)
       ((string=? xy "UU") 'both-modified)
       (else 'unmerged)))

    (define (vcs-parse-status-ordinary token)
      "Parse an ordinary porcelain v2 tracked-entry token."
      (let ((split (vcs-leading-fields token 8)))
        (let ((fields (car split))
              (path (cdr split)))
          (let ((xy (vcs-list-ref/default fields 1 ".."))
                (submodule (vcs-list-ref/default fields 2 "N...")))
            (let ((index-status (vcs-xy-index-status xy))
                  (worktree-status (vcs-xy-worktree-status xy)))
              (make-vcs-status-entry
               (vcs-status-kind index-status worktree-status)
               path
               index-status
               worktree-status
               (list
                (vcs-field 'xy xy)
                (vcs-field 'submodule (vcs-parse-submodule submodule))
                (vcs-field 'head-mode (vcs-list-ref/default fields 3 #f))
                (vcs-field 'index-mode (vcs-list-ref/default fields 4 #f))
                (vcs-field 'worktree-mode (vcs-list-ref/default fields 5 #f))
                (vcs-field 'head-object (vcs-list-ref/default fields 6 #f))
                (vcs-field 'index-object
                           (vcs-list-ref/default fields 7 #f)))))))))

    (define (vcs-parse-status-rename token orig-path)
      "Parse a porcelain v2 renamed or copied token plus its original path."
      (let ((split (vcs-leading-fields token 9)))
        (let ((fields (car split))
              (path (cdr split)))
          (let ((xy (vcs-list-ref/default fields 1 ".."))
                (submodule (vcs-list-ref/default fields 2 "N..."))
                (score-token (vcs-list-ref/default fields 8 "R0")))
            (let ((score-length (string-length score-token)))
              (let ((score (if (> score-length 1)
                               (string->number
                                (substring score-token 1 score-length))
                               0))
                    (kind (if (and (> score-length 0)
                                   (char=? (string-ref score-token 0) #\C))
                              'copied
                              'renamed)))
                (make-vcs-status-entry
                 kind
                 path
                 (vcs-xy-index-status xy)
                 (vcs-xy-worktree-status xy)
                 (list
                  (vcs-field 'xy xy)
                  (vcs-field 'submodule (vcs-parse-submodule submodule))
                  (vcs-field 'head-mode (vcs-list-ref/default fields 3 #f))
                  (vcs-field 'index-mode (vcs-list-ref/default fields 4 #f))
                  (vcs-field 'worktree-mode
                             (vcs-list-ref/default fields 5 #f))
                  (vcs-field 'head-object (vcs-list-ref/default fields 6 #f))
                  (vcs-field 'index-object
                             (vcs-list-ref/default fields 7 #f))
                  (vcs-field 'orig-path orig-path)
                  (vcs-field 'score (if score score 0))))))))))

    (define (vcs-parse-status-unmerged token)
      "Parse a porcelain v2 unmerged-entry token."
      (let ((split (vcs-leading-fields token 10)))
        (let ((fields (car split))
              (path (cdr split)))
          (let ((xy (vcs-list-ref/default fields 1 "UU")))
            (make-vcs-status-entry
             'conflicted
             path
             (vcs-xy-index-status xy)
             (vcs-xy-worktree-status xy)
             (list
              (vcs-field 'xy xy)
              (vcs-field 'submodule
                         (vcs-parse-submodule
                          (vcs-list-ref/default fields 2 "N...")))
              (vcs-field 'base-mode (vcs-list-ref/default fields 3 #f))
              (vcs-field 'ours-mode (vcs-list-ref/default fields 4 #f))
              (vcs-field 'theirs-mode (vcs-list-ref/default fields 5 #f))
              (vcs-field 'worktree-mode (vcs-list-ref/default fields 6 #f))
              (vcs-field 'base-object (vcs-list-ref/default fields 7 #f))
              (vcs-field 'ours-object (vcs-list-ref/default fields 8 #f))
              (vcs-field 'theirs-object (vcs-list-ref/default fields 9 #f))
              (vcs-field 'conflict
                         (make-vcs-conflict-state
                          (vcs-conflict-type xy)
                          (list path)))))))))

    (define (vcs-parse-status-other token kind)
      "Parse an untracked or ignored porcelain v2 path token."
      (let ((path (substring token 2 (string-length token))))
        (make-vcs-status-entry
         kind
         path
         kind
         kind
         '())))

    (define (parse-git-status-porcelain-v2-z text)
      "Parse Git status --porcelain=v2 -z --branch output into a status datum."
      #((parameters . ((text . "NUL-delimited output from `git status --porcelain=v2 -z --branch`.")))
        (returns . "A `vcs-status` datum with branch, entries, operation state, and parse outcome.")
        (effects . (pure))
        (see-also . (make-vcs-status make-vcs-status-entry parse-git-raw-diff-z)))
      (let loop ((tokens (vcs-split-nul text))
                 (oid #f)
                 (head #f)
                 (detached? #f)
                 (upstream #f)
                 (ahead 0)
                 (behind 0)
                 (entries '()))
        (if (null? tokens)
            (make-vcs-status
             'git
             (make-vcs-repository 'git #f #f)
             (make-vcs-branch head oid upstream ahead behind detached?)
             (reverse entries)
             (make-vcs-operation-state #f #f #f #f)
             (make-vcs-outcome 'ok "parsed git status porcelain v2"))
            (let ((token (car tokens))
                  (rest (cdr tokens)))
              (cond
               ((vcs-string-prefix? "# branch.oid " token)
                (let ((value (vcs-drop-prefix "# branch.oid " token)))
                  (loop rest
                        (if (string=? value "(initial)") #f value)
                        head
                        detached?
                        upstream
                        ahead
                        behind
                        entries)))
               ((vcs-string-prefix? "# branch.head " token)
                (let ((value (vcs-drop-prefix "# branch.head " token)))
                  (loop rest
                        oid
                        (if (string=? value "(detached)") #f value)
                        (string=? value "(detached)")
                        upstream
                        ahead
                        behind
                        entries)))
               ((vcs-string-prefix? "# branch.upstream " token)
                (loop rest
                      oid
                      head
                      detached?
                      (vcs-drop-prefix "# branch.upstream " token)
                      ahead
                      behind
                      entries))
               ((vcs-string-prefix? "# branch.ab " token)
                (let ((counts
                       (vcs-split-spaces
                        (vcs-drop-prefix "# branch.ab " token))))
                  (loop rest
                        oid
                        head
                        detached?
                        upstream
                        (vcs-parse-count (vcs-list-ref/default counts 0 "+0"))
                        (vcs-parse-count (vcs-list-ref/default counts 1 "-0"))
                        entries)))
               ((vcs-string-prefix? "1 " token)
                (loop rest
                      oid
                      head
                      detached?
                      upstream
                      ahead
                      behind
                      (cons (vcs-parse-status-ordinary token) entries)))
               ((vcs-string-prefix? "2 " token)
                (let ((orig-path (if (null? rest) "" (car rest))))
                  (loop (if (null? rest) rest (cdr rest))
                        oid
                        head
                        detached?
                        upstream
                        ahead
                        behind
                        (cons (vcs-parse-status-rename token orig-path)
                              entries))))
               ((vcs-string-prefix? "u " token)
                (loop rest
                      oid
                      head
                      detached?
                      upstream
                      ahead
                      behind
                      (cons (vcs-parse-status-unmerged token) entries)))
               ((vcs-string-prefix? "? " token)
                (loop rest
                      oid
                      head
                      detached?
                      upstream
                      ahead
                      behind
                      (cons (vcs-parse-status-other token 'untracked)
                            entries)))
               ((vcs-string-prefix? "! " token)
                (loop rest
                      oid
                      head
                      detached?
                      upstream
                      ahead
                      behind
                      (cons (vcs-parse-status-other token 'ignored)
                            entries)))
               (else
                (loop rest oid head detached? upstream ahead behind entries)))))))

    (define (vcs-raw-status-kind status-token)
      "Convert a Git raw diff status token to a normalized status symbol."
      (if (= (string-length status-token) 0)
          'unknown
          (vcs-status-char->symbol (string-ref status-token 0))))

    (define (vcs-raw-status-score status-token)
      "Return the score suffix from a raw diff status token, if any."
      (let ((length (string-length status-token)))
        (if (> length 1)
            (let ((score (string->number (substring status-token 1 length))))
              (if score score #f))
            #f)))

    (define (vcs-parse-raw-diff-record metadata rest)
      "Parse one raw diff metadata token and following path tokens."
      (let ((fields (vcs-split-spaces metadata)))
        (let ((old-mode-token (vcs-list-ref/default fields 0 ":000000"))
              (new-mode (vcs-list-ref/default fields 1 "000000"))
              (old-object (vcs-list-ref/default fields 2 "0000000"))
              (new-object (vcs-list-ref/default fields 3 "0000000"))
              (status-token (vcs-list-ref/default fields 4 "X")))
          (let ((old-mode
                 (if (> (string-length old-mode-token) 0)
                     (substring old-mode-token
                                1
                                (string-length old-mode-token))
                     old-mode-token))
                (status (vcs-raw-status-kind status-token))
                (score (vcs-raw-status-score status-token)))
            (if (or (eq? status 'renamed) (eq? status 'copied))
                (let ((orig-path (vcs-list-ref/default rest 0 ""))
                      (path (vcs-list-ref/default rest 1 "")))
                  (cons
                   (make-vcs-diff-file
                    status
                    path
                    orig-path
                    old-mode
                    new-mode
                    old-object
                    new-object
                    score)
                   (if (null? rest)
                       rest
                       (if (null? (cdr rest)) '() (cddr rest)))))
                (let ((path (vcs-list-ref/default rest 0 "")))
                  (cons
                   (make-vcs-diff-file
                    status
                    path
                    #f
                    old-mode
                    new-mode
                    old-object
                    new-object
                    score)
                   (if (null? rest) rest (cdr rest)))))))))

    (define (parse-git-raw-diff-z text)
      "Parse Git diff --raw -z output into a file-level summary datum."
      #((parameters . ((text . "NUL-delimited output from `git diff --raw -z` or compatible Git raw diff command.")))
        (returns . "A `vcs-diff-summary` datum containing file-level diff records.")
        (effects . (pure))
        (see-also . (make-vcs-diff-summary make-vcs-diff-file parse-git-status-porcelain-v2-z)))
      (let loop ((tokens (vcs-split-nul text))
                 (files '()))
        (cond
         ((null? tokens)
          (make-vcs-diff-summary 'git (reverse files)))
         ((vcs-string-prefix? ":" (car tokens))
          (let ((parsed (vcs-parse-raw-diff-record (car tokens) (cdr tokens))))
            (loop (cdr parsed) (cons (car parsed) files))))
         (else
          (loop (cdr tokens) files)))))))
