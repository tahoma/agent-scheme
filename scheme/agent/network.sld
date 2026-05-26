;;; network.sld --- Portable Agent Scheme network capability datums
;;;
;;; This host-neutral library owns canonical network request, grant, decision,
;;; response, stream handle, port capability, and audit records. Host adapters
;;; perform transport only after this vocabulary has produced an allowed
;;; decision.

(define-library (agent network)
  (export network-field
          network-field-value
          make-network-request
          network-request?
          network-request-id
          network-request-operation
          make-network-grant
          make-network-approval-decision
          make-network-capability-decision
          network-capability-decision?
          network-capability-decision-status
          network-authorize-request
          make-network-response
          make-network-stream-handle
          make-network-port-capability
          make-network-audit
          network-audit?)
  (import (scheme base))
  (begin
    (define (network-field name . values)
      "Return a Scheme-readable record field named NAME with VALUES."
      (cons name values))

    (define (network-field-value record field default)
      "Return FIELD's first value from RECORD, or DEFAULT when absent."
      (let ((entry (and (pair? record) (assq field (cdr record)))))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    ;; Report whether DATUM is a record tagged by TAG.
    (define (network-record? datum tag)
      (and (pair? datum) (eq? (car datum) tag)))

    ;; Return LIST's third element without relying on optional base aliases.
    (define (network-third list)
      (car (cdr (cdr list))))

    (define (make-network-request id operation resource)
      "Return a host-adapter request datum for one network operation."
      (list 'network-capability-request
            (network-field 'id id)
            (network-field 'operation operation)
            (network-field 'scheme
                           (network-resource-value resource 'scheme #f))
            (network-field 'host
                           (network-resource-value resource 'host #f))
            (network-field 'port
                           (network-resource-value resource 'port #f))
            (network-field 'method
                           (network-resource-value resource 'method #f))
            (network-field 'header-classes
                           (network-resource-value
                            resource
                            'header-classes
                            '()))
            (network-field 'payload-class
                           (network-resource-value
                            resource
                            'payload-class
                            'none))
            (network-field 'response-size
                           (network-resource-value
                            resource
                            'response-size
                            #f))
            (network-field 'redirects
                           (network-resource-value resource 'redirects 0))
            (network-field 'timeout-ms
                           (network-resource-value resource 'timeout-ms #f))
            (network-field 'stream-lifetime-ms
                           (network-resource-value
                            resource
                            'stream-lifetime-ms
                            #f))
            (network-field 'resource resource)))

    (define (network-request? datum)
      "Return #t when DATUM is a network request record."
      (network-record? datum 'network-capability-request))

    (define (network-request-id request)
      "Return REQUEST's stable identifier."
      (network-field-value request 'id #f))

    (define (network-request-operation request)
      "Return REQUEST's operation symbol."
      (network-field-value request 'operation #f))

    (define (make-network-grant id operations scope)
      "Return a scoped network authority grant record."
      (list 'network-capability-grant
            (network-field 'id id)
            (network-field 'operations operations)
            (network-field 'scope scope)))

    (define (make-network-approval-decision id request-id status reason)
      "Return an explicit approval decision for one network request."
      (list 'network-approval-decision
            (network-field 'id id)
            (network-field 'request-id request-id)
            (network-field 'status status)
            (network-field 'reason reason)))

    (define (make-network-capability-decision request status grant approval reason)
      "Return a network authorization decision record."
      (list 'network-capability-decision
            (network-field 'id (network-request-id request))
            (network-field 'operation (network-request-operation request))
            (network-field 'scheme (network-field-value request 'scheme #f))
            (network-field 'host (network-field-value request 'host #f))
            (network-field 'port (network-field-value request 'port #f))
            (network-field 'method (network-field-value request 'method #f))
            (network-field 'status status)
            (network-field 'grant
                           (if grant
                               (network-field-value grant 'id #f)
                               #f))
            (network-field 'approval
                           (if approval
                               (network-field-value approval 'id #f)
                               #f))
            (network-field 'reason reason)))

    (define (network-capability-decision? datum)
      "Return #t when DATUM is a network decision record."
      (network-record? datum 'network-capability-decision))

    (define (network-capability-decision-status decision)
      "Return DECISION's status symbol."
      (network-field-value decision 'status #f))

    (define (make-network-response id status fields)
      "Return a host-adapter response datum for a network operation."
      (append
       (list 'network-response
             (network-field 'id id)
             (network-field 'status status))
       fields))

    (define (make-network-stream-handle id request url grant status)
      "Return a Scheme-readable network stream handle datum."
      (list 'handle
            (network-field 'id id)
            (network-field 'kind 'network-stream)
            (network-field 'domain 'network)
            (network-field 'request request)
            (network-field 'url url)
            (network-field 'grant grant)
            (network-field 'status status)))

    (define (make-network-port-capability
             id kind stream-handle operations grant limits status)
      "Return a Scheme-readable network-backed port capability datum."
      (list 'port-capability
            (network-field 'id id)
            (network-field 'kind kind)
            (network-field 'backing 'network)
            (cons 'operations operations)
            (network-field 'grant grant)
            (cons 'limits limits)
            (network-field 'path stream-handle)
            (network-field 'status status)))

    (define (make-network-audit request decision result)
      "Return a stable audit event for a network authorization and result."
      (list 'network-capability-audit
            (network-field 'event 'network-capability-audit)
            (network-field 'id (network-request-id request))
            (network-field 'operation (network-request-operation request))
            (network-field 'scheme (network-field-value request 'scheme #f))
            (network-field 'host (network-field-value request 'host #f))
            (network-field 'port (network-field-value request 'port #f))
            (network-field 'method (network-field-value request 'method #f))
            (network-field 'decision
                           (network-capability-decision-status decision))
            (network-field 'result
                           (network-field-value result 'status #f))))

    (define (network-audit? datum)
      "Return #t when DATUM is a network audit record."
      (network-record? datum 'network-capability-audit))

    ;; Return RESOURCE's argument named FIELD, or DEFAULT when absent.
    (define (network-resource-value resource field default)
      (let ((entry (assq field resource)))
        (if entry
            (if (null? (cdr entry)) default (cadr entry))
            default)))

    ;; Report whether OPERATIONS covers OPERATION.
    (define (network-operation-covered? operation operations)
      (cond
       ((eq? operations 'all) #t)
       ((pair? operations)
        (if (or (memq operation operations) (memq 'all operations)) #t #f))
       (else
        (eq? operation operations))))

    ;; Return FIELD from GRANT's scope, or DEFAULT when absent.
    (define (network-grant-scope-value grant field default)
      (let ((scope (network-field-value grant 'scope '())))
        (network-resource-value scope field default)))

    ;; Return #t when VALUE is covered by SCOPE; #f and all mean unrestricted.
    (define (network-scope-value-covers? value scope)
      (or (not scope)
          (eq? scope 'all)
          (and (pair? scope) (member value scope))
          (equal? value scope)))

    ;; Return #t when every VALUE is covered by SCOPE.
    (define (network-scope-values-cover? values scope)
      (or (not scope)
          (eq? scope 'all)
          (let loop ((rest values))
            (or (null? rest)
                (and (network-scope-value-covers? (car rest) scope)
                     (loop (cdr rest)))))))

    ;; Return a human-readable denial reason for REQUEST under GRANT, or #f.
    (define (network-grant-denial request grant)
      (let ((operation (network-request-operation request)))
        (cond
         ((not (network-operation-covered?
                operation
                (network-field-value grant 'operations '())))
          "operation is outside approved network grant scope")
         ((not (network-scope-value-covers?
                (network-field-value request 'scheme #f)
                (network-grant-scope-value grant 'schemes #f)))
          "scheme is outside approved network grant scope")
         ((not (network-scope-value-covers?
                (network-field-value request 'host #f)
                (network-grant-scope-value grant 'hosts #f)))
          "host is outside approved network grant scope")
         ((not (network-scope-value-covers?
                (network-field-value request 'port #f)
                (network-grant-scope-value grant 'ports #f)))
          "port is outside approved network grant scope")
         ((not (network-scope-value-covers?
                (network-field-value request 'method #f)
                (network-grant-scope-value grant 'methods #f)))
          "method is outside approved network grant scope")
         ((not (network-scope-values-cover?
                (network-field-value request 'header-classes '())
                (network-grant-scope-value grant 'header-classes #f)))
          "header class is outside approved network grant scope")
         ((not (network-scope-value-covers?
                (network-field-value request 'payload-class 'none)
                (network-grant-scope-value grant 'payload-classes #f)))
          "payload class is outside approved network grant scope")
         ((let ((limit (network-grant-scope-value
                       grant
                       'max-response-bytes
                       #f))
                (size (network-field-value request 'response-size #f)))
            (and limit size (> size limit)))
          "response size is outside approved network grant scope")
         ((let ((limit (network-grant-scope-value grant 'max-redirects #f))
                (redirects (network-field-value request 'redirects 0)))
            (and limit (> redirects limit)))
          "redirect count is outside approved network grant scope")
         ((let ((limit (network-grant-scope-value grant 'max-timeout-ms #f))
                (timeout (network-field-value request 'timeout-ms #f)))
            (and limit timeout (> timeout limit)))
          "timeout is outside approved network grant scope")
         ((let ((limit (network-grant-scope-value
                       grant
                       'stream-lifetime-ms
                       #f))
                (lifetime (network-field-value
                           request
                           'stream-lifetime-ms
                           #f)))
            (and limit lifetime (> lifetime limit)))
          "stream lifetime is outside approved network grant scope")
         (else #f))))

    ;; Return the first grant that authorizes REQUEST, or the last denial tuple.
    (define (network-find-grant request grants)
      (let loop ((rest grants) (denied #f))
        (cond
         ((null? rest) denied)
         (else
          (let ((reason (network-grant-denial request (car rest))))
            (if reason
                (loop (cdr rest) (list 'denied (car rest) reason))
                (list 'approved (car rest))))))))

    ;; Report whether APPROVAL authorizes REQUEST.
    (define (network-approval-allows? request approval)
      (and (network-record? approval 'network-approval-decision)
           (equal? (network-request-id request)
                   (network-field-value approval 'request-id #f))
           (eq? (network-field-value approval 'status #f) 'approved)))

    ;; Return the first approval that authorizes REQUEST, or #f.
    (define (network-find-approval request approvals)
      (let loop ((rest approvals))
        (cond
         ((null? rest) #f)
         ((network-approval-allows? request (car rest)) (car rest))
         (else (loop (cdr rest))))))

    (define (network-authorize-request request grants approvals)
      "Return a fail-closed authorization decision for REQUEST."
      (let ((match (network-find-grant request grants)))
        (cond
         ((and match (eq? (car match) 'approved))
          (make-network-capability-decision
           request
           'approved
           (cadr match)
           #f
           "network request is covered by active grant"))
         ((network-find-approval request approvals)
          (make-network-capability-decision
           request
           'approved
           #f
           (network-find-approval request approvals)
           "authorized by network approval"))
         (else
          (make-network-capability-decision
           request
           'denied
           (and match (cadr match))
           #f
           (if match
               (network-third match)
               "no active network grant covers request"))))))))
