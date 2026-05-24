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
    ;; Return a Scheme-readable record field named NAME with VALUES.
    (define (vcs-field name . values)
      (cons name values))

    ;; Return FIELD's first value from RECORD, or DEFAULT when absent.
    (define (vcs-field-value record field default)
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    ;; Report whether DATUM is a record tagged by TAG.
    (define (vcs-record? datum tag)
      (and (pair? datum) (eq? (car datum) tag)))

    ;; Return an explicit repository identity/root record.
    (define (make-vcs-repository system root identity)
      (list 'vcs-repository
            (vcs-field 'system system)
            (vcs-field 'root root)
            (vcs-field 'identity identity)))

    ;; Return a branch or detached-head record.
    (define (make-vcs-branch head oid upstream ahead behind detached?)
      (list 'vcs-branch
            (vcs-field 'head head)
            (vcs-field 'oid oid)
            (vcs-field 'upstream upstream)
            (vcs-field 'ahead ahead)
            (vcs-field 'behind behind)
            (vcs-field 'detached? detached?)))

    ;; Return safe remote metadata without requiring a raw host remote object.
    (define (make-vcs-remote name url-metadata)
      (list 'vcs-remote
            (vcs-field 'name name)
            (vcs-field 'url url-metadata)))

    ;; Return a compact commit summary record suitable for log adapters.
    (define (make-vcs-commit-summary oid parents subject author timestamp)
      (list 'vcs-commit-summary
            (vcs-field 'oid oid)
            (vcs-field 'parents parents)
            (vcs-field 'subject subject)
            (vcs-field 'author author)
            (vcs-field 'timestamp timestamp)))

    ;; Return a repository status snapshot from pure Scheme-readable fields.
    (define (make-vcs-status system repository branch entries operation-state outcome)
      (list 'vcs-status
            (vcs-field 'system system)
            (vcs-field 'repository repository)
            (vcs-field 'branch branch)
            (vcs-field 'entries entries)
            (vcs-field 'operation-state operation-state)
            (vcs-field 'outcome outcome)))

    ;; Report whether DATUM is a VCS status record.
    (define (vcs-status? datum)
      (and (pair? datum) (eq? (car datum) 'vcs-status)))

    ;; Return STATUS's branch or detached-head record.
    (define (vcs-status-branch status)
      (vcs-field-value status 'branch #f))

    ;; Return STATUS's status entry list.
    (define (vcs-status-entries status)
      (vcs-field-value status 'entries '()))

    ;; Return a worktree/index status entry with additional DETAILS fields.
    (define (make-vcs-status-entry kind path index-status worktree-status details)
      (append
       (list 'vcs-status-entry
             (vcs-field 'kind kind)
             (vcs-field 'path path)
             (vcs-field 'index-status index-status)
             (vcs-field 'worktree-status worktree-status))
       details))

    ;; Report whether DATUM is a VCS status entry record.
    (define (vcs-status-entry? datum)
      (and (pair? datum) (eq? (car datum) 'vcs-status-entry)))

    ;; Return ENTRY's normalized kind.
    (define (vcs-status-entry-kind entry)
      (vcs-field-value entry 'kind #f))

    ;; Return ENTRY's repository-relative path.
    (define (vcs-status-entry-path entry)
      (vcs-field-value entry 'path #f))

    ;; Return ENTRY's index-side status.
    (define (vcs-status-entry-index-status entry)
      (vcs-field-value entry 'index-status #f))

    ;; Return ENTRY's worktree-side status.
    (define (vcs-status-entry-worktree-status entry)
      (vcs-field-value entry 'worktree-status #f))

    ;; Report whether ENTRY represents an unresolved conflict.
    (define (vcs-status-entry-conflict? entry)
      (eq? (vcs-field-value entry 'kind #f) 'conflicted))

    ;; Return merge/rebase/cherry-pick/bisect state as explicit data.
    (define (make-vcs-operation-state merge rebase cherry-pick bisect)
      (list 'vcs-operation-state
            (vcs-field 'merge merge)
            (vcs-field 'rebase rebase)
            (vcs-field 'cherry-pick cherry-pick)
            (vcs-field 'bisect bisect)))

    ;; Return conflict state independent of any host-native merge object.
    (define (make-vcs-conflict-state type paths)
      (list 'vcs-conflict-state
            (vcs-field 'type type)
            (vcs-field 'paths paths)))

    ;; Return a diff summary whose files may compose with `(agent diff)' hunks.
    (define (make-vcs-diff-summary system files)
      (list 'vcs-diff-summary
            (vcs-field 'system system)
            (vcs-field 'files files)))

    ;; Return one file-level raw diff summary.
    (define (make-vcs-diff-file status path orig-path old-mode new-mode old-object new-object score)
      (list 'vcs-diff-file
            (vcs-field 'status status)
            (vcs-field 'path path)
            (vcs-field 'orig-path orig-path)
            (vcs-field 'old-mode old-mode)
            (vcs-field 'new-mode new-mode)
            (vcs-field 'old-object old-object)
            (vcs-field 'new-object new-object)
            (vcs-field 'score score)))

    ;; Return DIFF's file summary list.
    (define (vcs-diff-summary-files diff)
      (vcs-field-value diff 'files '()))

    ;; Return a host-adapter request datum for a VCS operation.
    (define (make-vcs-capability-request id operation authority arguments)
      (list 'vcs-capability-request
            (vcs-field 'id id)
            (vcs-field 'operation operation)
            (vcs-field 'authority authority)
            (vcs-field 'arguments arguments)
            (vcs-field 'required-authority
                       (vcs-operation-required-authority operation))
            (vcs-field 'remote? (vcs-remote-operation? operation))
            (vcs-field 'mutating? (vcs-mutating-operation? operation))))

    ;; Report whether DATUM is a VCS capability request record.
    (define (vcs-capability-request? datum)
      (vcs-record? datum 'vcs-capability-request))

    ;; Return REQUEST's stable identifier.
    (define (vcs-capability-request-id request)
      (vcs-field-value request 'id #f))

    ;; Return REQUEST's operation symbol.
    (define (vcs-capability-request-operation request)
      (vcs-field-value request 'operation #f))

    ;; Return a host-adapter result datum for a VCS operation.
    (define (make-vcs-capability-result id status value)
      (list 'vcs-capability-result
            (vcs-field 'id id)
            (vcs-field 'status status)
            (vcs-field 'value value)))

    ;; Return a scoped VCS authority grant record.
    (define (make-vcs-capability-grant id authority operations repository remote)
      (list 'vcs-capability-grant
            (vcs-field 'id id)
            (vcs-field 'authority authority)
            (vcs-field 'operations operations)
            (vcs-field 'repository repository)
            (vcs-field 'remote remote)))

    ;; Return an explicit approval decision for one VCS request.
    (define (make-vcs-approval-decision id request-id status reason)
      (list 'vcs-approval-decision
            (vcs-field 'id id)
            (vcs-field 'request-id request-id)
            (vcs-field 'status status)
            (vcs-field 'reason reason)))

    ;; Return a VCS capability authorization decision record.
    (define (make-vcs-capability-decision request status grant approval reason)
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

    ;; Report whether DATUM is a VCS capability decision record.
    (define (vcs-capability-decision? datum)
      (vcs-record? datum 'vcs-capability-decision))

    ;; Return DECISION's status symbol.
    (define (vcs-capability-decision-status decision)
      (vcs-field-value decision 'status #f))

    ;; Return an explicit VCS outcome instead of a generic error.
    (define (make-vcs-outcome status message)
      (list 'vcs-outcome
            (vcs-field 'status status)
            (vcs-field 'message message)))

    ;; Return OUTCOME's status symbol.
    (define (vcs-outcome-status outcome)
      (vcs-field-value outcome 'status #f))

    ;; Report whether DATUM is a VCS outcome record.
    (define (vcs-outcome? datum)
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

    ;; Report whether OPERATION is a read-only VCS observation.
    (define (vcs-read-only-operation? operation)
      (if (memq operation vcs-read-only-operations) #t #f))

    ;; Report whether OPERATION mutates repository state.
    (define (vcs-mutating-operation? operation)
      (if (memq operation vcs-mutating-operations) #t #f))

    ;; Report whether OPERATION communicates with a remote VCS endpoint.
    (define (vcs-remote-operation? operation)
      (if (memq operation vcs-remote-operations) #t #f))

    ;; Return OPERATION's required policy authority family.
    (define (vcs-operation-required-authority operation)
      (cond
       ((vcs-read-only-operation? operation) 'read-only-observation)
       ((vcs-remote-operation? operation) 'remote-mutation)
       ((vcs-mutating-operation? operation) 'repository-mutation)
       (else 'unknown)))

    ;; Report whether STATUS is part of the shared outcome vocabulary.
    (define (vcs-known-outcome? status)
      (if (memq status vcs-known-outcomes) #t #f))

    ;; Return REQUEST's argument named NAME, or DEFAULT when absent.
    (define (vcs-request-argument request name default)
      (let ((arguments (vcs-field-value request 'arguments '())))
        (let loop ((rest arguments))
          (cond
           ((null? rest) default)
           ((and (pair? (car rest)) (eq? (car (car rest)) name))
            (let ((values (cdr (car rest))))
              (if (null? values) default (car values))))
           (else
            (loop (cdr rest)))))))

    ;; Report whether OPERATIONS covers OPERATION.
    (define (vcs-operation-covered? operation operations)
      (cond
       ((eq? operations 'all) #t)
       ((pair? operations)
        (if (or (memq operation operations) (memq 'all operations)) #t #f))
       (else
        (eq? operation operations))))

    ;; Report whether VALUE matches SCOPE, where #f and all mean unrestricted.
    (define (vcs-scope-matches? scope value)
      (or (not scope) (eq? scope 'all) (equal? scope value)))

    ;; Report whether GRANT authorizes REQUEST.
    (define (vcs-grant-allows? request grant)
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

    ;; Return the first GRANTS entry that authorizes REQUEST.
    (define (vcs-find-grant request grants)
      (let loop ((rest grants))
        (cond
         ((null? rest) #f)
         ((vcs-grant-allows? request (car rest)) (car rest))
         (else (loop (cdr rest))))))

    ;; Report whether APPROVAL authorizes REQUEST.
    (define (vcs-approval-allows? request approval)
      (and (vcs-record? approval 'vcs-approval-decision)
           (equal? (vcs-capability-request-id request)
                   (vcs-field-value approval 'request-id #f))
           (eq? (vcs-field-value approval 'status #f) 'approved)))

    ;; Return the first APPROVALS entry that authorizes REQUEST.
    (define (vcs-find-approval request approvals)
      (let loop ((rest approvals))
        (cond
         ((null? rest) #f)
         ((vcs-approval-allows? request (car rest)) (car rest))
         (else (loop (cdr rest))))))

    ;; Return a fail-closed authorization decision for REQUEST.
    (define (vcs-authorize-capability-request request grants approvals)
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

    ;; Return RESULT's VCS outcome status when it carries a VCS outcome.
    (define (vcs-result-outcome-status result)
      (let ((value (vcs-field-value result 'value #f)))
        (if (vcs-outcome? value)
            (vcs-outcome-status value)
            #f)))

    ;; Return a stable audit event for a VCS authorization and result.
    (define (make-vcs-capability-audit request decision result)
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

    ;; Report whether DATUM is a VCS capability audit record.
    (define (vcs-capability-audit? datum)
      (vcs-record? datum 'vcs-capability-audit))

    ;; Return non-#f when TEXT starts with PREFIX.
    (define (vcs-string-prefix? prefix text)
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

    ;; Return TEXT with PREFIX removed when present.
    (define (vcs-drop-prefix prefix text)
      (if (vcs-string-prefix? prefix text)
          (substring text (string-length prefix) (string-length text))
          text))

    ;; Return the first index of CHAR in TEXT at or after START, or #f.
    (define (vcs-string-index text char start)
      (let ((length (string-length text)))
        (let loop ((index start))
          (cond
           ((>= index length) #f)
           ((char=? (string-ref text index) char) index)
           (else (loop (+ index 1)))))))

    ;; Split TEXT on CHAR, dropping empty fields used as final terminators.
    (define (vcs-split-on-char text char)
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

    ;; Split a NUL-delimited Git machine-format string.
    (define (vcs-split-nul text)
      (vcs-split-on-char text #\null))

    ;; Split TEXT into space-separated metadata fields.
    (define (vcs-split-spaces text)
      (vcs-split-on-char text #\space))

    ;; Return the first COUNT fields and the remaining text after them.
    (define (vcs-leading-fields text count)
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

    ;; Return LIST's INDEX value, or DEFAULT when INDEX is out of range.
    (define (vcs-list-ref/default values index default)
      (let loop ((rest values) (cursor index))
        (cond
         ((null? rest) default)
         ((= cursor 0) (car rest))
         (else (loop (cdr rest) (- cursor 1))))))

    ;; Convert a signed Git count field such as +2 or -1 to a nonnegative count.
    (define (vcs-parse-count text)
      (let ((length (string-length text)))
        (let ((start
               (if (and (> length 0)
                        (or (char=? (string-ref text 0) #\+)
                            (char=? (string-ref text 0) #\-)))
                   1
                   0)))
          (let ((number (string->number (substring text start length))))
            (if number number 0)))))

    ;; Convert a one-character Git status code to an Agent Scheme symbol.
    (define (vcs-status-char->symbol char)
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

    ;; Convert a Git XY field to the index-side status.
    (define (vcs-xy-index-status xy)
      (if (> (string-length xy) 0)
          (vcs-status-char->symbol (string-ref xy 0))
          'unknown))

    ;; Convert a Git XY field to the worktree-side status.
    (define (vcs-xy-worktree-status xy)
      (if (> (string-length xy) 1)
          (vcs-status-char->symbol (string-ref xy 1))
          'unknown))

    ;; Return the status-entry kind implied by INDEX-STATUS and WORKTREE-STATUS.
    (define (vcs-status-kind index-status worktree-status)
      (cond
       ((not (eq? index-status 'unchanged)) index-status)
       ((not (eq? worktree-status 'unchanged)) worktree-status)
       (else 'unchanged)))

    ;; Parse the four-character porcelain v2 submodule field.
    (define (vcs-parse-submodule text)
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

    ;; Convert an unmerged XY field to a conflict type.
    (define (vcs-conflict-type xy)
      (cond
       ((string=? xy "DD") 'both-deleted)
       ((string=? xy "AU") 'added-by-us)
       ((string=? xy "UD") 'deleted-by-them)
       ((string=? xy "UA") 'added-by-them)
       ((string=? xy "DU") 'deleted-by-us)
       ((string=? xy "AA") 'both-added)
       ((string=? xy "UU") 'both-modified)
       (else 'unmerged)))

    ;; Parse an ordinary porcelain v2 tracked-entry token.
    (define (vcs-parse-status-ordinary token)
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

    ;; Parse a porcelain v2 renamed or copied token plus its original path.
    (define (vcs-parse-status-rename token orig-path)
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

    ;; Parse a porcelain v2 unmerged-entry token.
    (define (vcs-parse-status-unmerged token)
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

    ;; Parse an untracked or ignored porcelain v2 path token.
    (define (vcs-parse-status-other token kind)
      (let ((path (substring token 2 (string-length token))))
        (make-vcs-status-entry
         kind
         path
         kind
         kind
         '())))

    ;; Parse Git status --porcelain=v2 -z --branch output into a status datum.
    (define (parse-git-status-porcelain-v2-z text)
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

    ;; Convert a Git raw diff status token to a normalized status symbol.
    (define (vcs-raw-status-kind status-token)
      (if (= (string-length status-token) 0)
          'unknown
          (vcs-status-char->symbol (string-ref status-token 0))))

    ;; Return the score suffix from a raw diff status token, if any.
    (define (vcs-raw-status-score status-token)
      (let ((length (string-length status-token)))
        (if (> length 1)
            (let ((score (string->number (substring status-token 1 length))))
              (if score score #f))
            #f)))

    ;; Parse one raw diff metadata token and following path tokens.
    (define (vcs-parse-raw-diff-record metadata rest)
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

    ;; Parse Git diff --raw -z output into a file-level summary datum.
    (define (parse-git-raw-diff-z text)
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
