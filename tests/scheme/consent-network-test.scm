;;; Portable Agent Network semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (agent network)
        (testing registry)
        (testing runner)
        (stdlib testing))

(testing-registry-case
 'network-request-decision-audit '(agent network records)
 (let* ((request
         (make-network-request
          'req-http 'request
          '((scheme "https")
            (host "api.example.test")
            (port 443)
            (method GET)
            (headers (("X-Trace" "ok")))
            (payload-class public)
            (response-size 64))))
        (denied (network-authorize-request request '() '()))
        (grant
         (make-network-grant
          'grant-http '(request stream)
          '((schemes ("https"))
            (hosts ("api.example.test"))
            (ports (443))
            (methods (GET POST))
            (header-classes (metadata))
            (payload-classes (public redacted))
            (max-response-bytes 128)
            (max-redirects 0)
            (max-timeout-ms 1000)
            (stream-lifetime-ms 5000))))
        (allowed (network-authorize-request request (list grant) '()))
        (response
         (make-network-response 'req-http 'ok '((status 200) (body "ok"))))
        (audit (make-network-audit request allowed response)))
   (test-assert "request predicate" (network-request? request))
   (test-equal "default denial" 'denied
               (network-capability-decision-status denied))
   (test-equal "grant approval" 'approved
               (network-capability-decision-status allowed))
   (test-equal "selected grant" 'grant-http
               (network-field-value allowed 'grant #f))
   (test-assert "audit predicate" (network-audit? audit))
   (test-equal "audit result" 'ok
               (network-field-value audit 'result #f))))

(testing-registry-case
 'network-grant-denials '(agent network capability)
 (let* ((grant
         (make-network-grant
          'grant-http '(request)
          '((schemes ("https"))
            (hosts ("api.example.test"))
            (ports (443))
            (methods (GET))
            (header-classes (metadata))
            (payload-classes (public))
            (max-response-bytes 8)
            (max-redirects 0)
            (max-timeout-ms 1000))))
        (request
         (lambda (id host header-class response-size)
           (make-network-request
            id 'request
            `((scheme "https") (host ,host) (port 443) (method GET)
              (header-classes (,header-class)) (payload-class public)
              (response-size ,response-size) (redirects 0)))))
        (reason
         (lambda (candidate)
           (network-field-value
            (network-authorize-request candidate (list grant) '())
            'reason #f))))
   (test-equal
    "host scope"
    "host is outside approved network grant scope"
    (reason (request 'wrong-host "other.example.test" 'metadata 8)))
   (test-equal
    "header scope"
    "header class is outside approved network grant scope"
    (reason (request 'credential "api.example.test" 'credential 8)))
   (test-equal
    "response size scope"
    "response size is outside approved network grant scope"
    (reason (request 'too-large "api.example.test" 'metadata 9)))))

(testing-registry-case
 'network-handles '(agent network records)
 (test-equal
  "stream handle"
  '(handle
    (id h-stream-1)
    (kind network-stream)
    (domain network)
    (request req-stream)
    (url "https://api.example.test/events")
    (grant grant-stream)
    (status live))
  (make-network-stream-handle
   'h-stream-1 'req-stream "https://api.example.test/events"
   'grant-stream 'live))
 (test-equal
  "port capability"
  '(port-capability
    (id p-stream-1)
    (kind textual-input)
    (backing network)
    (operations read close)
    (grant grant-stream)
    (limits (reads 2))
    (path h-stream-1)
    (status open))
  (make-network-port-capability
   'p-stream-1 'textual-input 'h-stream-1 '(read close)
   'grant-stream '((reads 2)) 'open)))

(testing-runner-main "Agent Network portable semantics" (command-line))
