;;; agent-scheme-network-test.el --- Network capability datum tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the host-neutral `(agent network)' contract.

;;; Code:

(require 'ert)
(require 'agent-scheme-eval)
(require 'agent-scheme-result)

(defun agent-scheme-network-test--external (source)
  "Evaluate SOURCE and return its stable external value representation."
  (agent-scheme-value->external
   (agent-scheme-eval-source source)))

(ert-deftest agent-scheme-network-test-request-decision-and-audit-datums ()
  "Construct network request, grant, decision, response, and audit datums."
  (should
   (equal
    (agent-scheme-network-test--external
     "(import (scheme base) (agent network))
      (define request
        (make-network-request
         'req-http
         'request
         '((scheme \"https\")
           (host \"api.example.test\")
           (port 443)
           (method GET)
           (headers ((\"X-Trace\" \"ok\")))
           (payload-class public)
           (response-size 64))))
      (define denied
        (network-authorize-request request '() '()))
      (define grant
        (make-network-grant
         'grant-http
         '(request stream)
         '((schemes (\"https\"))
           (hosts (\"api.example.test\"))
           (ports (443))
           (methods (GET POST))
           (header-classes (metadata))
           (payload-classes (public redacted))
           (max-response-bytes 128)
           (max-redirects 0)
           (max-timeout-ms 1000)
           (stream-lifetime-ms 5000))))
      (define allowed
        (network-authorize-request request (list grant) '()))
      (define response
        (make-network-response
         'req-http
         'ok
         '((status 200) (body \"ok\"))))
      (define audit
        (make-network-audit request allowed response))
      (list (network-request? request)
            (network-capability-decision-status denied)
            (network-capability-decision-status allowed)
            (network-field-value allowed 'grant #f)
            (network-audit? audit)
            (network-field-value audit 'result #f))")
    "(#t denied approved grant-http #t ok)")))

(ert-deftest agent-scheme-network-test-grant-scope-denials ()
  "Network grants restrict host, method, headers, payload, redirects, and sizes."
  (should
   (equal
    (agent-scheme-network-test--external
     "(import (scheme base) (agent network))
      (define grant
        (make-network-grant
         'grant-http
         '(request)
         '((schemes (\"https\"))
           (hosts (\"api.example.test\"))
           (ports (443))
           (methods (GET))
           (header-classes (metadata))
           (payload-classes (public))
           (max-response-bytes 8)
           (max-redirects 0)
           (max-timeout-ms 1000))))
      (define wrong-host
        (make-network-request
         'wrong-host
         'request
         '((scheme \"https\") (host \"other.example.test\")
           (port 443) (method GET)
           (header-classes (metadata))
           (payload-class public)
           (response-size 8) (redirects 0))))
      (define credential
        (make-network-request
         'credential
         'request
         '((scheme \"https\") (host \"api.example.test\")
           (port 443) (method GET)
           (header-classes (credential))
           (payload-class public)
           (response-size 8) (redirects 0))))
      (define too-large
        (make-network-request
         'too-large
         'request
         '((scheme \"https\") (host \"api.example.test\")
           (port 443) (method GET)
           (header-classes (metadata))
           (payload-class public)
           (response-size 9) (redirects 0))))
      (list
       (network-field-value
        (network-authorize-request wrong-host (list grant) '())
        'reason
        #f)
       (network-field-value
        (network-authorize-request credential (list grant) '())
        'reason
        #f)
       (network-field-value
        (network-authorize-request too-large (list grant) '())
        'reason
        #f))")
    "(\"host is outside approved network grant scope\" \"header class is outside approved network grant scope\" \"response size is outside approved network grant scope\")")))

(ert-deftest agent-scheme-network-test-stream-handle-datum ()
  "Construct network stream and port capability handle datums."
  (should
   (equal
    (agent-scheme-network-test--external
     "(import (scheme base) (agent network))
      (list
       (make-network-stream-handle
        'h-stream-1
        'req-stream
        \"https://api.example.test/events\"
        'grant-stream
        'live)
       (make-network-port-capability
        'p-stream-1
        'textual-input
        'h-stream-1
        '(read close)
        'grant-stream
        '((reads 2))
        'open))")
    "((handle (id h-stream-1) (kind network-stream) (domain network) (request req-stream) (url \"https://api.example.test/events\") (grant grant-stream) (status live)) (port-capability (id p-stream-1) (kind textual-input) (backing network) (operations read close) (grant grant-stream) (limits (reads 2)) (path h-stream-1) (status open)))")))

;;; agent-scheme-network-test.el ends here
